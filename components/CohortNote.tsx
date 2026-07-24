'use client'

import { useState } from 'react'
import { PERIODOS_CURTOS, type Period } from '@/lib/utils'

// Explica a lógica de coorte (leads contados por data de nascimento, não por
// data do avanço) — importante para o usuário não estranhar CPAg alto em
// períodos curtos. Retrátil: quem já sabe pode fechar, mas reabre com o botão.
//
// Quando o período selecionado é curto, o aviso ganha um bloco extra: o número
// é útil para volume e investimento, mas não representa a conversão final.
export default function CohortNote({ period }: { period?: Period }) {
  const [open, setOpen] = useState(true)
  const curto = period !== undefined && PERIODOS_CURTOS.includes(period)

  if (!open) {
    return (
      <button className="cohort-note-collapsed" onClick={() => setOpen(true)}>
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><circle cx="12" cy="12" r="10" /><path d="M12 16v-4M12 8h.01" /></svg>
        Como os números desta aba são contados
      </button>
    )
  }

  return (
    <div className={`cohort-note ${curto ? 'is-short' : ''}`}>
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><circle cx="12" cy="12" r="10" /><path d="M12 16v-4M12 8h.01" /></svg>
      <div className="cohort-note-text">
        {curto && (
          <div className="cohort-note-warn">
            <strong>Período curto.</strong> Períodos curtos são úteis para
            acompanhar volume e investimento, mas podem não representar a
            conversão final do funil, pois parte dos leads ainda está em
            maturação.
          </div>
        )}
        <strong>Como os números desta aba são contados:</strong> um lead entra na
        safra do dia em que <em>nasceu</em>. Se ele agendar semanas depois, o
        agendamento aparece na safra de quando o lead começou — não na data do
        agendamento. Para ver o resultado mais &quot;maduro&quot; de uma
        campanha, prefira 30 ou 90 dias.
      </div>
      <button className="cohort-note-close" onClick={() => setOpen(false)} aria-label="Fechar">×</button>
    </div>
  )
}
