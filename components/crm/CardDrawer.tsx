'use client'

import { useEffect, useState } from 'react'
import {
  fetchHistory, fetchActivities, setOwner,
  fmtDataHora, fmtTelefone, classeEtapa,
  TAMANHO_MENSAGENS,
  type BoardCount, type CrmCard, type CrmHistoryEvent, type CrmActivity,
  type CrmOwner, type LossReason,
} from '@/lib/crm'
import { brl } from '@/lib/utils'
import MoveActions from '@/components/crm/MoveActions'

// O card aberto (IMP-207): dados, de qual anúncio veio, dono, histórico,
// conversa e as ações.
//
// A ADR-0013 decidiu que o atendimento continua no WhatsApp Web. Este painel
// abre a conversa, não a substitui — por isso "Abrir no WhatsApp" é a ação
// mais visível aqui, e não existe caixa de envio.

const MARCOS: Record<string, string> = {
  lead_received: 'Lead recebido',
  conversation_started: 'Primeira conversa',
  appointment: 'Agendamento',
  attendance: 'Comparecimento',
  proposal: 'Proposta',
  sale: 'Venda',
  revenue: 'Receita',
}

const ORIGENS: Record<string, string> = {
  frase_configurada: 'frase configurada',
  manual: 'manual',
  integracao: 'integração',
  sistema: 'automático',
}

export default function CardDrawer({
  card, stages, owners, lossReasons, canWrite, onClose, onChanged, onAviso,
}: {
  card: CrmCard
  stages: BoardCount[]
  owners: CrmOwner[]
  lossReasons: LossReason[]
  canWrite: boolean
  onClose: () => void
  onChanged: (card: CrmCard) => void
  onAviso: (msg: string) => void
}) {
  const [historico, setHistorico] = useState<CrmHistoryEvent[]>([])
  const [mensagens, setMensagens] = useState<CrmActivity[]>([])
  const [carregando, setCarregando] = useState(true)
  const [maisMsgs, setMaisMsgs] = useState(false)
  const [temMaisMsgs, setTemMaisMsgs] = useState(false)
  const [semImagem, setSemImagem] = useState(false)
  const [trocandoDono, setTrocandoDono] = useState(false)

  useEffect(() => {
    let alive = true
    setCarregando(true)
    setSemImagem(false)
    Promise.all([
      fetchHistory(card.client_id, card.opportunity_id),
      fetchActivities(card.client_id, card.contact_id),
    ]).then(([h, m]) => {
      if (!alive) return
      setHistorico(h)
      setMensagens(m)
      setTemMaisMsgs(m.length === TAMANHO_MENSAGENS)
      setCarregando(false)
    })
    return () => { alive = false }
    // `stage_version` entra de propósito: toda ação de etapa o incrementa, e é
    // isso que faz o histórico recarregar depois de mover, ganhar ou perder.
    // Sem ele, a linha do tempo mostraria o card sem o movimento que a pessoa
    // acabou de fazer.
  }, [card.client_id, card.opportunity_id, card.contact_id, card.stage_version])

  // Fechar com Esc: o drawer cobre a tela e o mouse nem sempre está por perto.
  useEffect(() => {
    function onKey(e: KeyboardEvent) { if (e.key === 'Escape') onClose() }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [onClose])

  async function carregarMaisMensagens() {
    setMaisMsgs(true)
    const novas = await fetchActivities(card.client_id, card.contact_id, mensagens.length)
    setMensagens((m) => [...m, ...novas])
    setTemMaisMsgs(novas.length === TAMANHO_MENSAGENS)
    setMaisMsgs(false)
  }

  async function trocaDono(profileId: string) {
    setTrocandoDono(true)
    const { card: novo, erro } = await setOwner(card.opportunity_id, profileId || null)
    setTrocandoDono(false)
    if (erro) { onAviso(erro.mensagem); return }
    if (novo) onChanged(novo)
  }

  const temAtribuicao = !!(card.campaign_name || card.ad_name || card.meta_ad_id)

  return (
    <div className="ag-drawer-backdrop" onClick={onClose}>
      <div className="ag-drawer" onClick={(e) => e.stopPropagation()}>
        <div className="ag-drawer-top">
          <div>
            <div className="ag-drawer-title">{card.contact_name || card.title}</div>
            <div className="ag-drawer-sub">
              <span className={`crm-badge ${classeEtapa(card.stage_code)}`}>{card.stage_label}</span>
            </div>
          </div>
          <button className="ag-drawer-close" onClick={onClose} aria-label="Fechar">×</button>
        </div>

        {card.whatsapp_url && (
          <a className="crm-wa" href={card.whatsapp_url} target="_blank" rel="noopener noreferrer">
            Abrir no WhatsApp Web
          </a>
        )}

        <div className="ag-drawer-section">Dados</div>
        <div className="ag-drawer-kv">
          <div><span>Telefone</span><b>{fmtTelefone(card.phone_normalized)}</b></div>
          <div><span>Aberto em</span><b>{fmtDataHora(card.opened_at)}</b></div>
          <div><span>Última atividade</span><b>{fmtDataHora(card.last_activity_at)}</b></div>
          <div>
            <span>Proprietário</span>
            {canWrite ? (
              <select
                className="select-native crm-owner"
                value={card.owner_profile_id ?? ''}
                disabled={trocandoDono}
                onChange={(e) => trocaDono(e.target.value)}
              >
                <option value="">Sem proprietário</option>
                {owners.map((o) => (
                  <option key={o.profile_id} value={o.profile_id}>
                    {o.display_name || 'Sem nome'}
                  </option>
                ))}
              </select>
            ) : (
              <b>{card.owner_name || 'Sem proprietário'}</b>
            )}
          </div>
        </div>

        <div className="ag-drawer-section">De onde veio este lead</div>
        {temAtribuicao ? (
          <div className="crm-origem">
            {card.thumbnail_url && !semImagem && (
              // URL assinada do fbcdn, com validade. Quando expira, some a
              // imagem e fica o nome do anúncio — melhor que ícone quebrado.
              // eslint-disable-next-line @next/next/no-img-element
              <img
                className="crm-origem-img"
                src={card.thumbnail_url}
                alt={card.ad_name ?? 'Criativo'}
                onError={() => setSemImagem(true)}
              />
            )}
            <div className="crm-origem-txt">
              {card.campaign_name && <div className="crm-origem-camp">{card.campaign_name}</div>}
              {card.adset_name && <div className="crm-origem-set">{card.adset_name}</div>}
              {card.ad_name && <div className="crm-origem-ad">{card.ad_name}</div>}
              {card.ad_title && <div className="crm-origem-title">“{card.ad_title}”</div>}
              <div className="crm-origem-meta">
                {card.conversion_source || 'Origem não informada'}
                {card.source_url && (
                  <>
                    {' · '}
                    <a href={card.source_url} target="_blank" rel="noopener noreferrer">ver publicação</a>
                  </>
                )}
              </div>
            </div>
          </div>
        ) : (
          <div className="ag-drawer-empty">
            Sem anúncio identificado. Este lead não entrou por um clique de anúncio do Meta.
          </div>
        )}

        {canWrite && (
          <>
            <div className="ag-drawer-section">Ações</div>
            <MoveActions
              card={card}
              stages={stages}
              lossReasons={lossReasons}
              onChanged={onChanged}
              onAviso={onAviso}
            />
          </>
        )}

        <div className="ag-drawer-section">Histórico</div>
        {carregando ? (
          <div className="ag-drawer-empty">Carregando…</div>
        ) : historico.length === 0 ? (
          <div className="ag-drawer-empty">Sem histórico registrado.</div>
        ) : (
          <div className="crm-timeline">
            {historico.map((h, i) => (
              <div key={`${h.occurred_at}-${h.event_kind}-${i}`} className="crm-tl-item">
                <div className="crm-tl-when">{fmtDataHora(h.occurred_at)}</div>
                <div className="crm-tl-what">
                  <Evento h={h} />
                  <div className="crm-tl-meta">
                    {ORIGENS[h.origin ?? ''] ?? h.origin}
                    {h.actor_name ? ` · ${h.actor_name}` : ''}
                  </div>
                  {/* `evidence` de marco é técnico ("whatsapp:primeira_resposta");
                      só o de outcome é texto que uma pessoa escreveu. */}
                  {(h.reason || (h.event_kind === 'outcome' && h.evidence)) && (
                    <div className="crm-tl-reason">{h.reason || h.evidence}</div>
                  )}
                </div>
              </div>
            ))}
          </div>
        )}

        <div className="ag-drawer-section">Conversa</div>
        {carregando ? (
          <div className="ag-drawer-empty">Carregando…</div>
        ) : mensagens.length === 0 ? (
          <div className="ag-drawer-empty">Sem mensagens registradas.</div>
        ) : (
          <>
            <div className="crm-msgs">
              {mensagens.map((m) => (
                <div key={m.activity_id} className={`crm-msg ${m.direction === 'inbound' ? 'in' : 'out'}`}>
                  <div className="crm-msg-body">{m.body || <i>(sem texto)</i>}</div>
                  <div className="crm-msg-when">{fmtDataHora(m.created_at)}</div>
                </div>
              ))}
            </div>
            {temMaisMsgs && (
              <button className="crm-col-more" disabled={maisMsgs} onClick={carregarMaisMensagens}>
                {maisMsgs ? 'Carregando…' : 'Carregar mais mensagens'}
              </button>
            )}
          </>
        )}

        <div className="muted-note" style={{ marginTop: 20 }}>
          O atendimento acontece no WhatsApp. Este painel mostra a conversa e move o card — não envia mensagem.
        </div>
      </div>
    </div>
  )
}

function Evento({ h }: { h: CrmHistoryEvent }) {
  if (h.event_kind === 'stage') {
    return (
      <span className="crm-tl-title">
        {h.from_stage_label ? `${h.from_stage_label} → ${h.to_stage_label}` : `Entrou em ${h.to_stage_label}`}
      </span>
    )
  }

  if (h.event_kind === 'milestone') {
    return <span className="crm-tl-title">{MARCOS[h.milestone_kind ?? ''] ?? h.milestone_kind}</span>
  }

  // outcome
  const ganho = h.outcome === 'won'
  return (
    <span className="crm-tl-title">
      {ganho ? 'Ganho' : 'Perdido'}
      {h.loss_reason_label ? ` · ${h.loss_reason_label}` : ''}
      {ganho && (
        h.value_status === 'valid' && h.value !== null
          ? ` · ${brl(Number(h.value), 2)}`
          : ' · valor pendente'
      )}
    </span>
  )
}
