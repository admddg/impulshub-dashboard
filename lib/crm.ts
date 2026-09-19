'use client'

import { supabase } from '@/lib/supabase'

// Porta única de entrada do CRM. Tudo que a aba lê ou escreve passa por aqui.
//
// Duas regras do projeto moram neste arquivo:
//
// 1. O frontend não recria metodologia do banco. Contagem de coluna, rótulo e
//    ordem de etapa, URL do WhatsApp e nome do anúncio vêm prontos das views.
//    Nada disso é calculado aqui.
//
// 2. Nunca ler coluna inteira. O PostgREST corta acima de ~1.000 linhas sem
//    erro nenhum. Toda leitura de lista aqui é explicitamente paginada, e a
//    contagem exibida vem do banco — nunca de `rows.length`.
//
// O schema `crm` não é alcançável pelo PostgREST: só o schema `public` é
// exposto. Por isso tudo aqui fala com as views `v_crm_*_v1` e as RPCs
// `crm_*`, descritas em docs/CONTRATO-TELA-CRM.md.

// ---------------------------------------------------------------- tipos

export type StageCode = 'lead' | 'atendimento' | 'agendado' | 'compareceu' | 'ganho' | 'perdido'

export type BoardCount = {
  client_id: string
  stage_code: StageCode
  stage_label: string
  stage_position: number
  is_terminal: boolean
  opportunities: number
}

export type CrmCard = {
  client_id: string
  opportunity_id: string
  contact_id: string
  contact_name: string | null
  phone_normalized: string | null
  whatsapp_url: string | null
  title: string
  stage_code: StageCode
  stage_label: string
  stage_position: number
  is_terminal: boolean
  status: 'open' | 'won' | 'lost'
  stage_version: number
  owner_profile_id: string | null
  owner_name: string | null
  opened_at: string
  closed_at: string | null
  last_activity_at: string | null
  meta_ad_id: string | null
  ad_name: string | null
  adset_name: string | null
  campaign_name: string | null
  creative_name: string | null
  thumbnail_url: string | null
  ctwa_clid: string | null
  conversion_source: string | null
  entry_point_conversion_source: string | null
  source_url: string | null
  ad_title: string | null
}

export type CrmContact = {
  client_id: string
  contact_id: string
  full_name: string | null
  phone_normalized: string | null
  email: string | null
  whatsapp_url: string | null
  status: string
  last_activity_at: string | null
  messages_total: number
  opportunity_id: string | null
  stage_code: StageCode | null
  stage_label: string | null
  stage_position: number | null
  opportunity_status: string | null
  search_text: string | null
}

export type CrmHistoryEvent = {
  occurred_at: string
  event_kind: 'stage' | 'milestone' | 'outcome'
  transition_type: string | null
  origin: string | null
  from_stage_code: string | null
  from_stage_label: string | null
  to_stage_code: string | null
  to_stage_label: string | null
  milestone_kind: string | null
  outcome: string | null
  loss_reason_code: string | null
  loss_reason_label: string | null
  value: number | null
  value_status: string | null
  currency: string | null
  evidence: string | null
  reason: string | null
  actor_profile_id: string | null
  actor_name: string | null
}

export type CrmActivity = {
  activity_id: string
  created_at: string
  kind: string
  direction: 'inbound' | 'outbound' | 'internal' | null
  body: string | null
}

export type CrmOwner = {
  profile_id: string
  display_name: string | null
  membership_role: string
  can_write: boolean
}

export type LossReason = {
  code: string
  label: string
  requires_note: boolean
  active: boolean
}

export type MyRole = { client_id: string; role: string | null; can_write: boolean }

// Colunas pedidas explicitamente: `select('*')` numa view larga traz o
// ctwa_clid inteiro (400+ caracteres) em toda linha do kanban sem motivo.
const CARD_COLS =
  'client_id, opportunity_id, contact_id, contact_name, phone_normalized, whatsapp_url, title, ' +
  'stage_code, stage_label, stage_position, is_terminal, status, stage_version, ' +
  'owner_profile_id, owner_name, opened_at, closed_at, last_activity_at, ' +
  'meta_ad_id, ad_name, adset_name, campaign_name, creative_name, thumbnail_url, ' +
  'ctwa_clid, conversion_source, entry_point_conversion_source, source_url, ad_title'

const CONTACT_COLS =
  'client_id, contact_id, full_name, phone_normalized, email, whatsapp_url, status, ' +
  'last_activity_at, messages_total, opportunity_id, stage_code, stage_label, ' +
  'stage_position, opportunity_status'

export const TAMANHO_COLUNA = 20
export const TAMANHO_PAGINA_CONTATOS = 50
export const TAMANHO_HISTORICO = 30
export const TAMANHO_MENSAGENS = 30

// ---------------------------------------------------------------- leitura

// O papel do usuário no cliente corrente. É o que esconde os botões de ação:
// um `viewer` enxerga tudo pela RLS, mas o trigger do banco recusa qualquer
// movimento dele. Melhor não oferecer o botão do que deixar tomar o erro.
export async function fetchMyRole(clientId: string): Promise<MyRole> {
  const { data, error } = await supabase
    .from('v_crm_my_role_v1')
    .select('client_id, role, can_write')
    .eq('client_id', clientId)
    .maybeSingle()

  if (error) {
    console.error('[Impuls] v_crm_my_role_v1:', error.message)
    return { client_id: clientId, role: null, can_write: false }
  }
  // Sem linha = sem permissão conhecida. O padrão seguro é não escrever.
  return (data as MyRole) ?? { client_id: clientId, role: null, can_write: false }
}

// Só quem pode escrever entra no seletor de dono: atribuir um card a quem o
// banco impede de mover cria uma fila que nunca anda.
export async function fetchOwners(clientId: string): Promise<CrmOwner[]> {
  const { data, error } = await supabase
    .from('v_crm_owners_v1')
    .select('profile_id, display_name, membership_role, can_write')
    .eq('client_id', clientId)
    .eq('can_write', true)
    .order('display_name')

  if (error) {
    console.error('[Impuls] v_crm_owners_v1:', error.message)
    return []
  }
  return (data ?? []) as CrmOwner[]
}

export async function fetchLossReasons(): Promise<LossReason[]> {
  const { data, error } = await supabase
    .from('v_crm_loss_reasons_v1')
    .select('code, label, requires_note, active')
    .eq('active', true)
    .order('label')

  if (error) {
    console.error('[Impuls] v_crm_loss_reasons_v1:', error.message)
    return []
  }
  return (data ?? []) as LossReason[]
}

// As 6 colunas do kanban, com a contagem JÁ AGREGADA no banco. São sempre 6
// linhas por cliente, inclusive as zeradas — uma coluna que some da tela
// esconderia que o pipeline está parado ali.
export async function fetchBoardCounts(clientId: string): Promise<BoardCount[]> {
  const { data, error } = await supabase
    .from('v_crm_board_counts_v1')
    .select('client_id, stage_code, stage_label, stage_position, is_terminal, opportunities')
    .eq('client_id', clientId)
    .order('stage_position')

  if (error) {
    console.error('[Impuls] v_crm_board_counts_v1:', error.message)
    return []
  }
  return (data ?? []) as BoardCount[]
}

// Uma página de cards de UMA coluna. Nunca a coluna inteira: hoje a Royal tem
// 162 em Atendimento, e isso só cresce.
export async function fetchCards(
  clientId: string,
  stageCode: StageCode,
  offset: number,
  limit: number = TAMANHO_COLUNA
): Promise<{ cards: CrmCard[]; erro: string | null }> {
  const { data, error } = await supabase
    .from('v_crm_cards_v1')
    .select(CARD_COLS)
    .eq('client_id', clientId)
    .eq('stage_code', stageCode)
    // Ordem estável e total: sem desempate por id, o .range() pode repetir ou
    // pular linha entre páginas quando duas têm a mesma data.
    .order('last_activity_at', { ascending: false, nullsFirst: false })
    .order('opportunity_id', { ascending: true })
    .range(offset, offset + limit - 1)

  if (error) {
    console.error(`[Impuls] v_crm_cards_v1 (${stageCode}):`, error.message)
    return { cards: [], erro: error.message }
  }
  return { cards: (data ?? []) as unknown as CrmCard[], erro: null }
}

// Um card só, pelo id. Usado quando o banco recusa um movimento por conflito
// de versão: recarregamos a verdade em vez de adivinhar o estado novo.
export async function fetchCard(clientId: string, opportunityId: string): Promise<CrmCard | null> {
  const { data, error } = await supabase
    .from('v_crm_cards_v1')
    .select(CARD_COLS)
    .eq('client_id', clientId)
    .eq('opportunity_id', opportunityId)
    .maybeSingle()

  if (error) {
    console.error('[Impuls] v_crm_cards_v1 (card):', error.message)
    return null
  }
  return (data as unknown as CrmCard) ?? null
}

// A busca usa `search_text`, que a view já entrega pronto (nome + telefone,
// minúsculo e sem acento).
//
// `%` e `_` são curingas do LIKE: sem escapar, quem digita "100%" recebe a
// lista inteira. E o PostgREST converte `*` em `%` antes de mandar para o
// Postgres, então o asterisco também precisa sair.
function escapaBusca(termo: string): string {
  return termo.trim().replace(/\*/g, '').replace(/[\\%_]/g, (c) => '\\' + c)
}

export async function fetchContacts(
  clientId: string,
  busca: string,
  page: number,
  pageSize: number = TAMANHO_PAGINA_CONTATOS
): Promise<{ rows: CrmContact[]; total: number; erro: string | null }> {
  let q = supabase
    .from('v_crm_contacts_v1')
    .select(CONTACT_COLS, { count: 'exact' })
    .eq('client_id', clientId)

  const termo = escapaBusca(busca)
  if (termo) q = q.ilike('search_text', `%${termo}%`)

  const { data, count, error } = await q
    .order('last_activity_at', { ascending: false, nullsFirst: false })
    .order('contact_id', { ascending: true })
    .range(page * pageSize, page * pageSize + pageSize - 1)

  if (error) {
    console.error('[Impuls] v_crm_contacts_v1:', error.message)
    return { rows: [], total: 0, erro: error.message }
  }
  // O total vem do servidor, não do tamanho da página.
  return { rows: (data ?? []) as unknown as CrmContact[], total: count ?? 0, erro: null }
}

export async function fetchHistory(
  clientId: string,
  opportunityId: string,
  offset: number = 0,
  limit: number = TAMANHO_HISTORICO
): Promise<CrmHistoryEvent[]> {
  const { data, error } = await supabase
    .from('v_crm_card_history_v1')
    .select(
      'occurred_at, event_kind, transition_type, origin, from_stage_code, from_stage_label, ' +
        'to_stage_code, to_stage_label, milestone_kind, outcome, loss_reason_code, ' +
        'loss_reason_label, value, value_status, currency, evidence, reason, ' +
        'actor_profile_id, actor_name'
    )
    .eq('client_id', clientId)
    .eq('opportunity_id', opportunityId)
    .order('occurred_at', { ascending: false })
    .range(offset, offset + limit - 1)

  if (error) {
    console.error('[Impuls] v_crm_card_history_v1:', error.message)
    return []
  }
  return (data ?? []) as unknown as CrmHistoryEvent[]
}

// Mensagens são escopadas por CONTATO, não por oportunidade: 5.827 das 8.887
// atividades não têm `opportunity_id`. Ler por oportunidade esconderia dois
// terços da conversa — e a tela pareceria certa.
export async function fetchActivities(
  clientId: string,
  contactId: string,
  offset: number = 0,
  limit: number = TAMANHO_MENSAGENS
): Promise<CrmActivity[]> {
  const { data, error } = await supabase
    .from('v_crm_activities_v1')
    .select('activity_id, created_at, kind, direction, body')
    .eq('client_id', clientId)
    .eq('contact_id', contactId)
    .order('created_at', { ascending: false })
    .range(offset, offset + limit - 1)

  if (error) {
    console.error('[Impuls] v_crm_activities_v1:', error.message)
    return []
  }
  return (data ?? []) as unknown as CrmActivity[]
}

// ---------------------------------------------------------------- escrita

// As 4 RPCs devolvem `SETOF v_crm_cards_v1`, então o retorno chega como ARRAY
// mesmo sendo uma linha só.
export type ResultadoAcao = { card: CrmCard | null; erro: ErroCrm | null }

export type ErroCrm = { codigo: string; mensagem: string }

const MENSAGENS: Record<string, string> = {
  CRM_STAGE_CONFLICT:
    'Outra pessoa moveu este card enquanto você o tinha aberto. Recarregamos o card com o estado atual.',
  CRM_FORBIDDEN: 'Você não tem permissão para alterar este card.',
  CRM_TERMINAL: 'Este card já foi fechado como Ganho ou Perdido.',
  CRM_REASON_REQUIRED: 'Voltar um card para uma etapa anterior exige um motivo.',
  CRM_EVIDENCE_REQUIRED: 'A observação é obrigatória para registrar o ganho.',
  CRM_NOTE_REQUIRED: 'O motivo "Outro" exige uma observação.',
  CRM_INVALID_VALUE: 'Valor inválido. Deixe em branco se o valor ainda não foi informado.',
  CRM_INVALID_REASON: 'Motivo de perda inválido.',
  // A tela só oferece etapas que vieram do banco, então este não deveria
  // aparecer. Está mapeado para não cair na mensagem genérica se aparecer.
  CRM_INVALID_STAGE: 'Etapa desconhecida.',
  CRM_INVALID_OWNER: 'Essa pessoa não pode ser dona de um card neste cliente.',
  CRM_USE_OUTCOME_RPC: 'Ganho e Perdido são registrados pelo próprio card.',
}

// O banco levanta erro com prefixo estável. Tratar pelo prefixo, nunca pelo
// texto livre: a frase pode mudar, o código não.
export function traduzErro(error: { message?: string; code?: string } | null): ErroCrm {
  const bruto = error?.message ?? ''
  const achado = Object.keys(MENSAGENS).find((c) => bruto.includes(c))

  if (achado) return { codigo: achado, mensagem: MENSAGENS[achado] }

  // 23514 é um CHECK do banco que escapou das guardas da RPC. Não deveria
  // acontecer: se aparecer, é bug do contrato e precisa chegar ao console.
  if (error?.code === '23514') {
    console.error('[Impuls] CHECK do banco recusou a escrita do CRM:', bruto)
    return { codigo: '23514', mensagem: 'O banco recusou esta alteração. Avise a equipe.' }
  }

  if (bruto) console.error('[Impuls] erro na escrita do CRM:', bruto)
  return { codigo: 'DESCONHECIDO', mensagem: 'Não foi possível salvar. Tente de novo.' }
}

async function chamaRpc(nome: string, args: Record<string, unknown>): Promise<ResultadoAcao> {
  const { data, error } = await supabase.rpc(nome, args)
  if (error) return { card: null, erro: traduzErro(error) }

  // SETOF: vem array com uma linha.
  const linha = Array.isArray(data) ? data[0] : data
  if (!linha) {
    console.error(`[Impuls] ${nome} não devolveu linha`)
    return { card: null, erro: { codigo: 'SEM_RETORNO', mensagem: 'Não foi possível salvar. Tente de novo.' } }
  }
  return { card: linha as CrmCard, erro: null }
}

export function moveStage(
  opportunityId: string,
  toStageCode: StageCode,
  expectedStageVersion: number,
  reason?: string | null
): Promise<ResultadoAcao> {
  return chamaRpc('crm_move_stage', {
    p_opportunity_id: opportunityId,
    p_to_stage_code: toStageCode,
    p_expected_stage_version: expectedStageVersion,
    p_reason: reason?.trim() || null,
  })
}

export function setOwner(opportunityId: string, ownerProfileId: string | null): Promise<ResultadoAcao> {
  return chamaRpc('crm_set_owner', {
    p_opportunity_id: opportunityId,
    p_owner_profile_id: ownerProfileId,
  })
}

// `valor` chega como string vinda do input. Vazio vira null — NUNCA zero.
// `Number('')` é 0, e o banco aceitaria como valor informado: seria uma venda
// de R$ 0,00 em produção, que é pior que valor nenhum.
export function registerWon(
  opportunityId: string,
  evidence: string,
  expectedStageVersion: number,
  valor: string
): Promise<ResultadoAcao> {
  const limpo = valor.trim()
  const numero = limpo === '' ? null : Number(limpo.replace(/\./g, '').replace(',', '.'))

  return chamaRpc('crm_register_won', {
    p_opportunity_id: opportunityId,
    p_evidence: evidence.trim(),
    p_expected_stage_version: expectedStageVersion,
    p_value: numero,
    p_currency: numero === null ? null : 'BRL',
  })
}

export function registerLost(
  opportunityId: string,
  lossReasonCode: string,
  expectedStageVersion: number,
  note?: string | null
): Promise<ResultadoAcao> {
  return chamaRpc('crm_register_lost', {
    p_opportunity_id: opportunityId,
    p_loss_reason_code: lossReasonCode,
    p_expected_stage_version: expectedStageVersion,
    p_note: note?.trim() || null,
  })
}

// ---------------------------------------------------------------- formato

export function fmtDataHora(iso: string | null): string {
  if (!iso) return '—'
  return new Date(iso).toLocaleString('pt-BR', {
    day: '2-digit', month: '2-digit', year: '2-digit', hour: '2-digit', minute: '2-digit',
  })
}

export function fmtDataCurta(iso: string | null): string {
  if (!iso) return '—'
  return new Date(iso).toLocaleDateString('pt-BR', { day: '2-digit', month: '2-digit', year: '2-digit' })
}

// Telefone só para leitura humana. O link do WhatsApp vem pronto da view.
export function fmtTelefone(phone: string | null): string {
  if (!phone) return '—'
  const m = phone.match(/^55(\d{2})(\d{4,5})(\d{4})$/)
  return m ? `(${m[1]}) ${m[2]}-${m[3]}` : phone
}

// Modificador do selo de etapa. Classe própria do CRM de propósito: o
// `.badge` que Leads e Eventos usam não existe no globals.css, e inventar a
// definição agora mudaria a aparência daquelas abas sem tarefa para isso.
export function classeEtapa(code: StageCode | null): string {
  switch (code) {
    case 'ganho': return 'is-won'
    case 'perdido': return 'is-lost'
    case 'agendado':
    case 'compareceu': return 'is-mid'
    default: return 'is-new'
  }
}
