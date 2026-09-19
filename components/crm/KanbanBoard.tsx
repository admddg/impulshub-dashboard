'use client'

import KanbanColumn from '@/components/crm/KanbanColumn'
import type { BoardCount, CrmCard, CrmFiltros } from '@/lib/crm'

// As 6 colunas. A ordem, os rótulos e as contagens vêm de `crm_board_counts`,
// já com o filtro aplicado — o frontend não conhece o pipeline nem conta
// linha, só desenha o que o banco devolve. Se um dia o pipeline mudar, esta
// tela acompanha sozinha.

export default function KanbanBoard({
  clientId, stages, canWrite, resetToken, filtros, onOpen, onActed, onAviso,
}: {
  clientId: string
  stages: BoardCount[]
  canWrite: boolean
  resetToken: number
  filtros: CrmFiltros
  onOpen: (card: CrmCard) => void
  onActed: () => void
  onAviso: (msg: string) => void
}) {
  // A próxima etapa é a seguinte em `stage_position`, e só quando não é
  // terminal: Ganho e Perdido exigem motivo, valor ou observação, então não
  // cabem num botão de avanço. Eles vivem no card aberto.
  function proxima(stage: BoardCount): BoardCount | null {
    const prox = stages.find((s) => s.stage_position === stage.stage_position + 1)
    if (!prox || prox.is_terminal) return null
    return prox
  }

  return (
    <div className="crm-board">
      {stages.map((stage) => (
        <KanbanColumn
          key={stage.stage_code}
          clientId={clientId}
          stage={stage}
          nextStage={proxima(stage)}
          canWrite={canWrite}
          resetToken={resetToken}
          filtros={filtros}
          onOpen={onOpen}
          onActed={onActed}
          onAviso={onAviso}
        />
      ))}
    </div>
  )
}
