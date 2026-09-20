'use client'

import { supabase } from '@/lib/supabase'
import { diaDeHojeSPISO } from '@/lib/utils'
import { valorMonetarioRpcEhValido } from '@/lib/crm-money'

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

// Filtros do topo da aba. `owner` é um campo só de propósito: os três estados
// são mutuamente exclusivos e o banco trata `p_unassigned` com precedência
// sobre `p_owner_profile_id`, então dois campos separados só criariam a
// chance de mandar os dois e descobrir a precedência do jeito difícil.
//   ''      → todos
//   'none'  → sem proprietário
//   <uuid>  → aquele proprietário
export type CrmFiltros = {
  de: string // 'YYYY-MM-DD'; '' = sem limite inferior
  ate: string // 'YYYY-MM-DD'; '' = sem limite superior
  owner: string
}

export const SEM_PROPRIETARIO = 'none'

// Constante compartilhada, não literal novo a cada chamada: assim
// `setFiltros(FILTROS_VAZIOS)` com filtro já vazio não dispara recarga.
export const FILTROS_VAZIOS: CrmFiltros = { de: '', ate: '', owner: '' }

export function temFiltro(f: CrmFiltros): boolean {
  return !!(f.de || f.ate || f.owner)
}

// O dia seguinte, em aritmética de data pura e em UTC.
//
// É isto que faz a contagem bater com os cards. `crm_board_counts` usa
// `opened_at < (p_opened_to + 1)`, ou seja o dia final inteiro entra. Do lado
// dos cards o equivalente é `.lt('opened_at', diaSeguinte(ate))` — com
// `.lte(ate)` perderíamos todo card aberto depois da meia-noite do último dia.
//
// E o `+1` é feito em UTC porque o banco também roda em UTC: com `new Date()`
// em horário local, um navegador em fuso positivo devolveria o dia errado.
export function diaSeguinte(dataISO: string): string {
  const d = new Date(dataISO + 'T00:00:00Z')
  d.setUTCDate(d.getUTCDate() + 1)
  return d.toISOString().slice(0, 10)
}

// Presets do filtro de data. Eles NÃO são um segundo caminho de filtragem:
// preenchem exatamente o mesmo par `de`/`ate` que os campos manuais, e daí em
// diante tudo — a RPC de contagem e a query de cards — segue idêntico.
export type PresetData = 'todos' | '7d' | '30d' | 'custom'

function somaDias(dataISO: string, n: number): string {
  const d = new Date(dataISO + 'T00:00:00Z')
  d.setUTCDate(d.getUTCDate() + n)
  return d.toISOString().slice(0, 10)
}

// "7 dias" são 7 dias civis contando hoje — `hoje - 6` até `hoje`, a mesma
// contagem que `getRanges` usa nas outras abas (`end - (n - 1)`). A diferença
// é só que o CRM inclui hoje e o dashboard fecha em D-1, porque aqui o lead
// entra ao vivo.
//
// `hoje - 6` e não `hoje - 7`: o segundo devolveria 8 dias civis sob um rótulo
// que diz 7. Medido na Royal em 19/09: 157 contra 174.
export function intervaloDoPreset(preset: PresetData): { de: string; ate: string } {
  if (preset !== '7d' && preset !== '30d') return { de: '', ate: '' }
  const ate = diaDeHojeSPISO()
  const dias = preset === '7d' ? 7 : 30
  return { de: somaDias(ate, -(dias - 1)), ate }
}

// A aba abre nos últimos 7 dias, não em tudo.
//
// A razão é de operação, não de velocidade: o filtro não deixa a tela mais
// rápida — a coluna busca sempre 20 cards e a contagem vem sempre agregada,
// com ou sem filtro. O que muda é o que o atendente vê primeiro, que é a fila
// da semana em vez do histórico inteiro.
//
// O custo é real e está à vista: card aberto há mais de 7 dias não aparece na
// abertura. Medido em 19/09 — 21 na Royal, 13 na QuickClean, 0 na Central.
// Por isso a barra sempre mostra o intervalo por extenso e "Todos" fica a um
// clique: quem abrir não pode achar que o resto sumiu.
export const PRESET_PADRAO: PresetData = '7d'

let padraoEmCache: CrmFiltros | null = null

// Devolve o MESMO objeto enquanto o dia não virar, para que reaplicar o padrão
// não dispare uma recarga à toa.
export function filtrosPadrao(): CrmFiltros {
  const { de, ate } = intervaloDoPreset(PRESET_PADRAO)
  if (!padraoEmCache || padraoEmCache.de !== de || padraoEmCache.ate !== ate) {
    padraoEmCache = { de, ate, owner: '' }
  }
  return padraoEmCache
}

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
//
// Sempre pela RPC, com ou sem filtro. A view `v_crm_board_counts_v1` não
// aceita parâmetro: usá-la com filtro ativo faria o topo contar o conjunto
// inteiro enquanto a coluna mostra o subconjunto — "Atendimento 173" com 12
// cards na tela, e ninguém sabendo em qual acreditar. Sem filtro a função
// devolve exatamente o mesmo que a view, então não há motivo para ter dois
// caminhos.
export async function fetchBoardCounts(
  clientId: string,
  filtros: CrmFiltros = FILTROS_VAZIOS
): Promise<BoardCount[]> {
  const { data, error } = await supabase.rpc('crm_board_counts', {
    p_client_id: clientId,
    p_opened_from: filtros.de || null,
    p_opened_to: filtros.ate || null,
    // `p_unassigned` tem precedência no banco; mandar os dois seria pedir para
    // depender dessa precedência em vez de ser explícito.
    p_owner_profile_id:
      filtros.owner && filtros.owner !== SEM_PROPRIETARIO ? filtros.owner : null,
    p_unassigned: filtros.owner === SEM_PROPRIETARIO,
  })

  if (error) {
    console.error('[Impuls] crm_board_counts:', error.message)
    return []
  }

  // A função agrupa mas não ordena. São 6 linhas, e a ordem é a `position` que
  // o próprio banco devolveu — não é metodologia recriada aqui.
  return [...((data ?? []) as BoardCount[])].sort((a, b) => a.stage_position - b.stage_position)
}


// Uma página de cards de UMA coluna. Nunca a coluna inteira: hoje a Royal tem
// 162 em Atendimento, e isso só cresce.
export async function fetchCards(
  clientId: string,
  stageCode: StageCode,
  offset: number,
  limit: number = TAMANHO_COLUNA,
  filtros: CrmFiltros = FILTROS_VAZIOS
): Promise<{ cards: CrmCard[]; erro: string | null }> {
  let q = supabase
    .from('v_crm_cards_v1')
    .select(CARD_COLS)
    .eq('client_id', clientId)
    .eq('stage_code', stageCode)

  // Os mesmos predicados que `crm_board_counts` aplica, na mesma semântica.
  // Se estes dois blocos divergirem, o número no topo da coluna deixa de
  // bater com os cards e ninguém descobre por quê.
  if (filtros.de) q = q.gte('opened_at', filtros.de)
  if (filtros.ate) q = q.lt('opened_at', diaSeguinte(filtros.ate))
  if (filtros.owner === SEM_PROPRIETARIO) q = q.is('owner_profile_id', null)
  else if (filtros.owner) q = q.eq('owner_profile_id', filtros.owner)

  const { data, error } = await q
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

// Os mesmos filtros do kanban valem aqui. `opened_at` e `owner_profile_id`
// entraram em `v_crm_contacts_v1` pela migration 20260925000003, vindos da
// oportunidade MAIS RECENTE do contato — não do contato.
//
// Consequência: contato sem oportunidade tem os dois nulos e some assim que
// houver filtro de data, porque `null >= data` é nulo. É o comportamento certo
// — "criado em" só faz sentido para quem tem oportunidade.
//
// As colunas não entram no `select`: filtrar por coluna não selecionada é
// normal no PostgREST, e a lista não precisa exibi-las.
export async function fetchContacts(
  clientId: string,
  busca: string,
  page: number,
  pageSize: number = TAMANHO_PAGINA_CONTATOS,
  filtros: CrmFiltros = FILTROS_VAZIOS
): Promise<{ rows: CrmContact[]; total: number; erro: string | null }> {
  let q = supabase
    .from('v_crm_contacts_v1')
    .select(CONTACT_COLS, { count: 'exact' })
    .eq('client_id', clientId)

  // Semântica idêntica à de `fetchCards` e à de `crm_board_counts`.
  if (filtros.de) q = q.gte('opened_at', filtros.de)
  if (filtros.ate) q = q.lt('opened_at', diaSeguinte(filtros.ate))

  if (filtros.owner === SEM_PROPRIETARIO) {
    // `.is(owner_profile_id, null)` sozinho traria também quem não tem
    // oportunidade nenhuma — nulo por ausência de oportunidade, não porque
    // ninguém pegou o lead. Na Royal isso é 308 contra os 178 do kanban, para
    // o mesmo filtro. Exigir a oportunidade alinha as duas visões e deixa o
    // filtro de proprietário tratar as mesmas linhas que o de data já trata.
    q = q.is('owner_profile_id', null).not('opportunity_id', 'is', null)
  } else if (filtros.owner) {
    // Aqui o recorte já é automático: sem oportunidade, `owner_profile_id` é
    // nulo e `= <uuid>` não casa.
    q = q.eq('owner_profile_id', filtros.owner)
  }

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

// O valor já chega validado pela fronteira da UI. `null` significa pendente;
// um número representa o valor exato enviado para a RPC.
export function registerWon(
  opportunityId: string,
  evidence: string,
  expectedStageVersion: number,
  valor: number | null
): Promise<ResultadoAcao> {
  if (!valorMonetarioRpcEhValido(valor)) {
    return Promise.resolve({
      card: null,
      erro: { codigo: 'CRM_INVALID_VALUE', mensagem: MENSAGENS.CRM_INVALID_VALUE },
    })
  }

  return chamaRpc('crm_register_won', {
    p_opportunity_id: opportunityId,
    p_evidence: evidence.trim(),
    p_expected_stage_version: expectedStageVersion,
    p_value: valor,
    p_currency: valor === null ? null : 'BRL',
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
