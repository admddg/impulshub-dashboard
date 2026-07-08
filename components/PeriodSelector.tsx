'use client'

import { useState } from 'react'
import { type Period, type CustomRange } from '@/lib/utils'

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

  function applyCustom() {
    if (start && end && start <= end) {
      onChange('custom', { start, end })
      setOpen(false)
    }
  }

  return (
    <div className="periods-wrap">
      <div className="periods">
        <button className={`period ${period === '7d' ? 'active' : ''}`} onClick={() => onChange('7d')}>7 dias</button>
        <button className={`period ${period === '30d' ? 'active' : ''}`} onClick={() => onChange('30d')}>30 dias</button>
        <button className={`period custom ${period === 'custom' ? 'active' : ''}`} onClick={() => setOpen((o) => !o)}>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><rect x="3" y="4" width="18" height="18" rx="2" /><path d="M16 2v4M8 2v4M3 10h18" /></svg>
          {period === 'custom' && custom ? `${fmtBR(custom.start)} – ${fmtBR(custom.end)}` : 'Datas'}
        </button>
      </div>

      {open && (
        <div className="period-pop">
          <div className="period-pop-row">
            <label>De<input type="date" value={start} onChange={(e) => setStart(e.target.value)} /></label>
            <label>Até<input type="date" value={end} onChange={(e) => setEnd(e.target.value)} /></label>
          </div>
          <button className="period-apply" onClick={applyCustom} disabled={!start || !end || start > end}>Aplicar</button>
        </div>
      )}
    </div>
  )
}

function fmtBR(iso: string) {
  const [y, m, d] = iso.split('-')
  return `${d}/${m}`
}
