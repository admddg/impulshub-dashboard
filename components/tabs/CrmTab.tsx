'use client'

import { useCallback, useEffect, useState } from 'react'
import {
  fetchMyRole, fetchOwners, fetchLossReasons, fetchBoardCounts,
  type BoardCount, type CrmCard, type CrmOwner, type LossReason,
} from '@/lib/crm'
import KanbanBoard from '@/components/crm/KanbanBoard'
import ContactsList from '@/components/crm/ContactsList'
import CardDrawer from '@/components/crm/CardDrawer'

// A aba CRM. Duas visões da mesma base: o kanban, para trabalhar a fila, e a
// lista, para achar uma pessoa pelo nome ou telefone.
//
// Esta aba não tem seletor de período: kanban é estado atual, não recorte de
// tempo. Um "últimos 30 dias" aqui esconderia card antigo ainda aberto.

type Visao = 'kanban' | 'lista'

export default function CrmTab({ clientId }: { clientId: string }) {
  const [carregando, setCarregando] = useState(true)
  const [visao, setVisao] = useState<Visao>('kanban')
  const [canWrite, setCanWrite] = useState(false)
  const [stages, setStages] = useState<BoardCount[]>([])
  const [owners, setOwners] = useState<CrmOwner[]>([])
  const [lossReasons, setLossReasons] = useState<LossReason[]>([])
  const [aberto, setAberto] = useState<CrmCard | null>(null)
  const [aviso, setAviso] = useState('')

  // Muda a cada ação de escrita bem-sucedida. As colunas observam e recarregam
  // a primeira página: depois de mover um card, a verdade do kanban é o banco.
  const [resetToken, setResetToken] = useState(0)

  const recarregaContagens = useCallback(async () => {
    const counts = await fetchBoardCounts(clientId)
    setStages(counts)
  }, [clientId])

  useEffect(() => {
    let alive = true
    setCarregando(true)
    setAberto(null)
    setAviso('')

    Promise.all([
      fetchMyRole(clientId),
      fetchOwners(clientId),
      fetchLossReasons(),
      fetchBoardCounts(clientId),
    ]).then(([role, owners, reasons, counts]) => {
      if (!alive) return
      setCanWrite(role.can_write)
      setOwners(owners)
      setLossReasons(reasons)
      setStages(counts)
      setCarregando(false)
    })

    return () => { alive = false }
  }, [clientId])

  // Uma ação mudou alguma coisa no banco: recarrega as contagens (6 linhas) e
  // manda as colunas se reconstruírem. Não recalculamos o board na mão.
  async function aposAcao() {
    await recarregaContagens()
    setResetToken((t) => t + 1)
  }

  // O drawer devolve o card que a RPC retornou. Ele vira a verdade na tela, e
  // o board se refaz porque a etapa pode ter mudado.
  function cardAlterado(card: CrmCard) {
    setAberto(card)
    aposAcao()
  }

  if (carregando) {
    return <div className="state"><div className="spinner" />Carregando CRM…</div>
  }

  // Sem etapas pode ser cliente fora do CRM ou falha na consulta. A tela não
  // escolhe uma causa que não sabe — o detalhe real está no console.
  if (stages.length === 0) {
    return (
      <div className="state">
        Não há pipeline de CRM para este cliente, ou não foi possível carregá-lo.
      </div>
    )
  }

  const totalCards = stages.reduce((s, e) => s + e.opportunities, 0)

  return (
    <>
      <div className="crm-toolbar">
        <div className="sortbtns">
          <button className={`sortbtn ${visao === 'kanban' ? 'active' : ''}`} onClick={() => setVisao('kanban')}>
            Kanban
          </button>
          <button className={`sortbtn ${visao === 'lista' ? 'active' : ''}`} onClick={() => setVisao('lista')}>
            Contatos
          </button>
        </div>
        {!canWrite && (
          <span className="crm-readonly">Somente leitura</span>
        )}
      </div>

      {aviso && (
        <div className="crm-aviso">
          {aviso}
          <button onClick={() => setAviso('')} aria-label="Fechar aviso">×</button>
        </div>
      )}

      {visao === 'kanban' ? (
        <KanbanBoard
          clientId={clientId}
          stages={stages}
          canWrite={canWrite}
          resetToken={resetToken}
          onOpen={setAberto}
          onActed={aposAcao}
          onAviso={setAviso}
        />
      ) : (
        <ContactsList clientId={clientId} onOpen={setAberto} onAviso={setAviso} />
      )}

      {aberto && (
        <CardDrawer
          card={aberto}
          stages={stages}
          owners={owners}
          lossReasons={lossReasons}
          canWrite={canWrite}
          onClose={() => setAberto(null)}
          onChanged={cardAlterado}
          onAviso={setAviso}
        />
      )}

      <div className="muted-note">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><circle cx="12" cy="12" r="10" /><path d="M12 16v-4M12 8h.01" /></svg>
        {totalCards.toLocaleString('pt-BR')} oportunidades abertas. Etapa, contagem e histórico vêm
        prontos do banco — o painel não recalcula nenhum deles.
      </div>
    </>
  )
}
