'use client'

import { useState } from 'react'

// Explica a lógica de coorte (leads contados por data de nascimento, não por
// data do avanço) — importante para o usuário não estranhar CPAg alto em
// períodos curtos. Retrátil: quem já sabe pode fechar, mas reabre com o botão.
export default function CohortNote() {
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
        <strong>Como os números desta aba são contados:</strong> um lead entra na
        safra do dia em que <em>nasceu</em>. Se ele agendar semanas depois, o
        agendamento aparece na safra de quando o lead começou — não na data do
        agendamento. Por isso, períodos recentes (ex: 15 dias) tendem a mostrar
        menos agendamentos e CPA mais alto: parte dos leads ainda não teve
        tempo de avançar no funil. Para ver o resultado mais "maduro" de uma
        campanha, prefira 30 ou 90 dias.
      </div>
      <button className="cohort-note-close" onClick={() => setOpen(false)} aria-label="Fechar">×</button>
    </div>
  )
}
