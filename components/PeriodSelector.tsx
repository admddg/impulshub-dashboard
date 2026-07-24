'use client'

import { useState } from 'react'
import { dataDeCorteISO, dataDeCorteLabel, type Period, type CustomRange } from '@/lib/utils'

const OPCOES: { id: Period; label: string }[] = [
  { id: '7d', label: '7 dias' },
  { id: '15d', label: '15 dias' },
  { id: '30d', label: '30 dias' },
  { id: '90d', label: '90 dias' },
]

export default function PeriodSelector({
  period, custom, onChange,
}: {
  period: Period
  custom: CustomRange | null
  onChange: (p: Period, c?: CustomRange) => void
}) {
  const [open, setOpen] = useState(false)
  const [start, setStart] = useState(custom?.start ?? '')
  const [end, setEnd] = useState(custom?.end ?? '')

  // Não existe dado de mídia do dia corrente: o sync fecha em D-1. Travar o
  // input evita que o usuário escolha um intervalo que já nasce incompleto.
  const maxData = dataDeCorteISO()

  function applyCustom() {
    if (start && end && start <= end) {
      onChange('custom', { start, end: end > maxData ? maxData : end })
      setOpen(false)
    }
  }

  return (
    <div className="periods-wrap">
      <div className="periods">
        {OPCOES.map((o) => (
          <button
            key={o.id}
            className={`period ${period === o.id ? 'active' : ''}`}
            onClick={() => onChange(o.id)}
          >
            {o.label}
          </button>
        ))}
        <button className={`period custom ${period === 'custom' ? 'active' : ''}`} onClick={() => setOpen((o) => !o)}>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><rect x="3" y="4" width="18" height="18" rx="2" /><path d="M16 2v4M8 2v4M3 10h18" /></svg>
          {period === 'custom' && custom ? `${fmtBR(custom.start)} – ${fmtBR(custom.end)}` : 'Datas'}
        </button>
      </div>

      <div className="period-cutoff">Dados até {dataDeCorteLabel()}</div>

      {open && (
        <div className="period-pop">
          <div className="period-pop-row">
            <label>De<input type="date" max={maxData} value={start} onChange={(e) => setStart(e.target.value)} /></label>
            <label>Até<input type="date" max={maxData} value={end} onChange={(e) => setEnd(e.target.value)} /></label>
          </div>
          <button className="period-apply" onClick={applyCustom} disabled={!start || !end || start > end}>Aplicar</button>
        </div>
      )}
    </div>
  )
}

function fmtBR(iso: string) {
  const [, m, d] = iso.split('-')
  return `${d}/${m}`
}
