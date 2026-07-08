'use client'

import { deltaPct } from '@/lib/utils'

type Props = {
  label: string
  value: string          // já formatado (ex: "2.418")
  prefix?: string        // ex: "R$"
  suffix?: string        // ex: "x"
  current: number        // valor numérico do período atual (pra calcular delta)
  previous: number       // valor numérico do período anterior
  primary?: boolean      // card destacado (petróleo)
  small?: boolean        // card menor (eficiências)
  invert?: boolean       // true para métricas de custo: cair = bom (verde)
  prevLabel?: string     // texto do "vs." — default mostra o valor anterior
}

// Setas em SVG
function ArrowUp() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
      <path d="M7 17L17 7M17 7H8M17 7v9" />
    </svg>
  )
}
function ArrowDown() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
      <path d="M7 7l10 10M17 17H8m9 0V8" />
    </svg>
  )
}

export default function KpiCard({
  label, value, prefix, suffix, current, previous,
  primary, small, invert, prevLabel,
}: Props) {
  const pct = deltaPct(current, previous)

  // Define a "direção visual" (subiu/desceu) e se isso é bom ou ruim.
  let deltaClass = 'flat'
  let arrow: React.ReactNode = null
  let deltaText = '—'

  if (pct !== null) {
    const rose = pct >= 0
    // Para custo (invert), subir é ruim. Para volume/receita, subir é bom.
    const isGood = invert ? !rose : rose
    deltaClass = isGood ? 'up' : 'down'
    arrow = rose ? <ArrowUp /> : <ArrowDown />
    deltaText = `${Math.abs(pct).toFixed(0)}%`
  }

  const cardClass = ['kpi', primary ? 'primary' : '', small ? 'sm' : ''].filter(Boolean).join(' ')

  return (
    <div className={cardClass}>
      <div className="kpi-label">{label}</div>
      <div className="kpi-value">
        {prefix && <span className="cur">{prefix}</span>}
        {value}
        {suffix && <span className="cur" style={{ marginLeft: 3 }}>{suffix}</span>}
      </div>
      <span className={`kpi-delta ${deltaClass}`}>
        {arrow}
        {deltaText}
        {pct !== null && (
          <span className="prev">{prevLabel ?? 'vs. período ant.'}</span>
        )}
      </span>
    </div>
  )
}
