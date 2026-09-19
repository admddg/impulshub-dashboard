'use client'

import { useEffect, useState } from 'react'
import {
  fetchCards, fetchCard, moveStage, fmtDataCurta,
  TAMANHO_COLUNA,
  type BoardCount, type CrmCard, type CrmFiltros,
} from '@/lib/crm'

// Uma coluna do kanban. Cada coluna busca a própria página: assim a coluna
// vazia não dispara query nenhuma, e a cheia não puxa tudo.
//
// A contagem no topo vem de `v_crm_board_counts_v1`, agregada no banco. Nunca
// de `cards.length`, que é só o que já foi carregado.

export default function KanbanColumn({
  clientId, stage, nextStage, canWrite, resetToken, filtros, onOpen, onActed, onAviso,
}: {
  clientId: string
  stage: BoardCount
  nextStage: BoardCount | null
  canWrite: boolean
  resetToken: number
  filtros: CrmFiltros
  onOpen: (card: CrmCard) => void
  onActed: () => void
  onAviso: (msg: string) => void
}) {
  const [cards, setCards] = useState<CrmCard[]>([])
  const [carregando, setCarregando] = useState(true)
  const [carregandoMais, setCarregandoMais] = useState(false)
  const [ocupado, setOcupado] = useState<string | null>(null)
  const [falhou, setFalhou] = useState(false)

  const total = stage.opportunities

  useEffect(() => {
    let alive = true

    // Coluna vazia não faz request. Hoje quatro das seis estão zeradas nos
    // três clientes: são quatro viagens ao servidor que não precisam existir.
    if (total === 0) {
      setCards([])
      setCarregando(false)
      return
    }

    setCarregando(true)
    fetchCards(clientId, stage.stage_code, 0, TAMANHO_COLUNA, filtros).then(({ cards, erro }) => {
      if (!alive) return
      setCards(cards)
      setFalhou(!!erro)
      setCarregando(false)
    })
    return () => { alive = false }
    // `filtros` entra nas dependências mesmo com `resetToken` já cobrindo a
    // troca de filtro: é o que garante que a primeira página e o "carregar
    // mais" usem sempre o mesmo recorte que a contagem do topo.
  }, [clientId, stage.stage_code, total, resetToken, filtros])

  async function carregarMais() {
    setCarregandoMais(true)
    const { cards: novos } = await fetchCards(clientId, stage.stage_code, cards.length, TAMANHO_COLUNA, filtros)
    setCards((atuais) => [...atuais, ...novos])
    setCarregandoMais(false)
  }

  // Avançar para a próxima etapa. É a ação de maioria; voltar, Ganho e Perdido
  // ficam no card aberto, onde cabe o campo de motivo, valor e observação.
  async function avancar(card: CrmCard) {
    if (!nextStage) return
    setOcupado(card.opportunity_id)

    const { erro } = await moveStage(card.opportunity_id, nextStage.stage_code, card.stage_version)

    if (erro) {
      onAviso(erro.mensagem)
      // Conflito de versão: recarrega a verdade do banco em vez de adivinhar.
      if (erro.codigo === 'CRM_STAGE_CONFLICT') {
        const atual = await fetchCard(clientId, card.opportunity_id)
        if (atual) setCards((cs) => cs.map((c) => (c.opportunity_id === atual.opportunity_id ? atual : c)))
        else onActed()
      }
      setOcupado(null)
      return
    }

    setOcupado(null)
    onActed()
  }

  const podeCarregarMais = cards.length < total

  return (
    <div className="crm-col">
      <div className="crm-col-head">
        <span className="crm-col-name">{stage.stage_label}</span>
        <span className="crm-col-count">{total.toLocaleString('pt-BR')}</span>
      </div>

      <div className="crm-col-body">
        {carregando ? (
          <div className="crm-col-empty">Carregando…</div>
        ) : falhou ? (
          // O topo da coluna mostra a contagem real do banco. Se a busca dos
          // cards falhou, dizer "nenhum card" seria mentira — e é exatamente o
          // tipo de erro silencioso que já custou caro neste projeto.
          <div className="crm-col-empty">Não foi possível carregar esta coluna.</div>
        ) : total === 0 ? (
          <div className="crm-col-empty">Nenhum card</div>
        ) : (
          <>
            {cards.map((card) => (
              <div key={card.opportunity_id} className="crm-card">
                <button className="crm-card-open" onClick={() => onOpen(card)}>
                  <span className="crm-card-name">{card.contact_name || card.title}</span>
                  {/* A linha do anúncio existe SEMPRE, mesmo vazia. Quando ela
                      era condicional, o card sem campanha tinha uma estrutura
                      diferente no DOM — e nenhuma regra de CSS alcança um
                      elemento que não existe. São poucos cards (4 no sistema
                      inteiro), raros o bastante para não aparecer por acaso e
                      quebrar a coluna depois. */}
                  <span className="crm-card-ad" title={card.campaign_name ?? ''}>
                    {card.campaign_name ?? ''}
                  </span>
                  <span className="crm-card-meta">
                    {card.owner_name ? card.owner_name : 'Sem proprietário'}
                    {' · '}
                    {fmtDataCurta(card.last_activity_at)}
                  </span>
                </button>

                {canWrite && nextStage && !card.is_terminal && (
                  <button
                    className="crm-card-next"
                    disabled={ocupado === card.opportunity_id}
                    onClick={() => avancar(card)}
                    title={`Mover para ${nextStage.stage_label}`}
                  >
                    {ocupado === card.opportunity_id ? '…' : `${nextStage.stage_label} →`}
                  </button>
                )}
              </div>
            ))}

            {podeCarregarMais && (
              <button className="crm-col-more" disabled={carregandoMais} onClick={carregarMais}>
                {carregandoMais
                  ? 'Carregando…'
                  : `Carregar mais ${Math.min(TAMANHO_COLUNA, total - cards.length)}`}
              </button>
            )}
          </>
        )}
      </div>
    </div>
  )
}
