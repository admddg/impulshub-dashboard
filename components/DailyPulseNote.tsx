'use client'

import { useState } from 'react'

// Explica a lógica desta aba (data real do evento, sem coorte) — o
// complemento operacional das abas com coorte. Mesmo estilo do CohortNote,
// retrátil, para consistência visual.
export default function DailyPulseNote() {
  const [open, setOpen] = useState(true)

  if (!open) {
    return (
      <button className="cohort-note-collapsed" onClick={() => setOpen(true)}>
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><circle cx="12" cy="12" r="10" /><path d="M12 16v-4M12 8h.01" /></svg>
        Como os números desta aba são contados
      </button>
    )
  }

  return (
    <div className="cohort-note">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><circle cx="12" cy="12" r="10" /><path d="M12 16v-4M12 8h.01" /></svg>
      <div className="cohort-note-text">
        <strong>Como os números desta aba são contados:</strong> aqui é
        diferente do resto do dashboard — cada evento (lead, agendamento,
        ganho...) conta no dia em que <em>aconteceu de verdade</em>, sem
        olhar para quando o lead nasceu. É uma visão de acompanhamento do dia
        a dia, para saber "o que está acontecendo agora" — não para avaliar
        o resultado maduro de uma campanha ou período (para isso, use as
        outras abas, que seguem a lógica de safra/coorte).
      </div>
      <button className="cohort-note-close" onClick={() => setOpen(false)} aria-label="Fechar">×</button>
    </div>
  )
}
