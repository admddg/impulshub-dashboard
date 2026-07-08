'use client'

import {
  ResponsiveContainer, LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip,
  BarChart, Bar, Cell, PieChart, Pie,
} from 'recharts'

const PETROL = '#00313d'
const MINT = '#5fae95'
const LINE = '#e5e9ec'
const FAINT = '#8794a0'

// Tooltip customizado, sóbrio.
function Tip({ active, payload, label, fmt }: any) {
  if (!active || !payload?.length) return null
  return (
    <div style={{
      background: '#fff', border: `1px solid ${LINE}`, borderRadius: 8,
      padding: '8px 11px', boxShadow: '0 2px 8px rgba(0,49,61,.1)', fontSize: 12,
    }}>
      <div style={{ color: FAINT, marginBottom: 4, fontWeight: 600 }}>{label}</div>
      {payload.map((p: any, i: number) => (
        <div key={i} style={{ color: PETROL, display: 'flex', alignItems: 'center', gap: 6 }}>
          <span style={{ width: 8, height: 8, borderRadius: 2, background: p.color || p.fill, display: 'inline-block' }} />
          {p.name}: <strong>{fmt ? fmt(p.value) : p.value}</strong>
        </div>
      ))}
    </div>
  )
}

// -------- Gráfico de linha: evolução no tempo --------
// data: [{ label: '28/06', leads: 17, receita: 0 }, ...]
// series: [{ key: 'leads', name: 'Leads', color: '#00313d' }]
export function LineTimeChart({ data, series, fmt }: {
  data: any[]
  series: { key: string; name: string; color: string }[]
  fmt?: (v: number) => string
}) {
  return (
    <ResponsiveContainer width="100%" height={260}>
      <LineChart data={data} margin={{ top: 8, right: 12, left: 0, bottom: 0 }}>
        <CartesianGrid stroke={LINE} vertical={false} />
        <XAxis dataKey="label" tick={{ fill: FAINT, fontSize: 11 }} tickLine={false} axisLine={{ stroke: LINE }} />
        <YAxis tick={{ fill: FAINT, fontSize: 11 }} tickLine={false} axisLine={false} width={44} />
        <Tooltip content={<Tip fmt={fmt} />} />
        {series.map((s) => (
          <Line key={s.key} type="monotone" dataKey={s.key} name={s.name}
            stroke={s.color} strokeWidth={2.5} dot={false} activeDot={{ r: 4 }} />
        ))}
      </LineChart>
    </ResponsiveContainer>
  )
}

// -------- Gráfico de funil: barras decrescentes --------
// stages: [{ name: 'Leads', value: 118 }, { name: 'Primeira conversa', value: 64 }, ...]
export function FunnelChart({ stages }: { stages: { name: string; value: number }[] }) {
  const max = Math.max(...stages.map((s) => s.value), 1)
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
      {stages.map((s, i) => {
        const width = Math.max((s.value / max) * 100, 2)
        // gradiente sutil do petróleo (topo) ao menta (fundo do funil)
        const t = stages.length > 1 ? i / (stages.length - 1) : 0
        const color = i === 0 ? PETROL : i === stages.length - 1 ? MINT : `color-mix(in srgb, ${PETROL} ${100 - t * 100}%, ${MINT})`
        const prev = i > 0 ? stages[i - 1].value : null
        const conv = prev && prev > 0 ? Math.round((s.value / prev) * 100) : null
        return (
          <div key={s.name} style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
            <div style={{ width: 130, fontSize: 12.5, color: '#546069', textAlign: 'right', flexShrink: 0 }}>{s.name}</div>
            <div style={{ flex: 1, position: 'relative', height: 34, background: '#f0f3f4', borderRadius: 6, overflow: 'hidden' }}>
              <div style={{
                width: `${width}%`, height: '100%', background: color,
                borderRadius: 6, display: 'flex', alignItems: 'center', paddingLeft: 12,
                transition: 'width .4s ease', minWidth: 40,
              }}>
                <span style={{ color: '#fff', fontSize: 13, fontWeight: 650 }}>{s.value.toLocaleString('pt-BR')}</span>
              </div>
            </div>
            <div style={{ width: 52, fontSize: 11.5, color: FAINT, flexShrink: 0 }}>
              {conv !== null ? `${conv}%` : ''}
            </div>
          </div>
        )
      })}
    </div>
  )
}

// -------- Barras horizontais: comparação (ex: canais) --------
// data: [{ label: 'Meta Ads', value: 2418, color: '#00313d' }, ...]
export function HBarChart({ data, fmt, height = 260 }: {
  data: { label: string; value: number; color: string }[]
  fmt?: (v: number) => string
  height?: number
}) {
  return (
    <ResponsiveContainer width="100%" height={height}>
      <BarChart data={data} layout="vertical" margin={{ top: 4, right: 16, left: 0, bottom: 0 }}>
        <CartesianGrid stroke={LINE} horizontal={false} />
        <XAxis type="number" tick={{ fill: FAINT, fontSize: 11 }} tickLine={false} axisLine={{ stroke: LINE }} />
        <YAxis type="category" dataKey="label" tick={{ fill: '#546069', fontSize: 11.5 }} tickLine={false} axisLine={false} width={130} />
        <Tooltip content={<Tip fmt={fmt} />} cursor={{ fill: 'rgba(0,49,61,.04)' }} />
        <Bar dataKey="value" name="Valor" radius={[0, 5, 5, 0]} barSize={22}>
          {data.map((d, i) => <Cell key={i} fill={d.color} />)}
        </Bar>
      </BarChart>
    </ResponsiveContainer>
  )
}

// -------- Gráfico de pizza com legenda lateral --------
// data: [{ label: 'Lead Forms', value: 332, color: '#00313d' }, ...]
export function PieWithLegend({ data, fmt }: {
  data: { label: string; value: number; color: string }[]
  fmt?: (v: number) => string
}) {
  const total = data.reduce((s, d) => s + d.value, 0)
  return (
    <div className="pie-wrap">
      <ResponsiveContainer width="100%" height={240}>
        <PieChart>
          <Pie data={data} dataKey="value" nameKey="label" cx="50%" cy="50%" innerRadius={55} outerRadius={95} paddingAngle={2}>
            {data.map((d, i) => <Cell key={i} fill={d.color} />)}
          </Pie>
          <Tooltip content={<Tip fmt={fmt} />} />
        </PieChart>
      </ResponsiveContainer>
      <div className="pie-legend">
        {data.map((d, i) => (
          <div className="pie-legend-item" key={i}>
            <span className="pie-legend-dot" style={{ background: d.color }} />
            {d.label}
            <span className="pie-legend-val">{fmt ? fmt(d.value) : d.value}{total > 0 ? ` · ${Math.round((d.value / total) * 100)}%` : ''}</span>
          </div>
        ))}
      </div>
    </div>
  )
}

// -------- Gráfico de colunas verticais (evolução no tempo) --------
export function ColumnChart({ data, fmt, color = '#00313d' }: {
  data: { label: string; value: number }[]
  fmt?: (v: number) => string
  color?: string
}) {
  return (
    <ResponsiveContainer width="100%" height={260}>
      <BarChart data={data} margin={{ top: 8, right: 12, left: 0, bottom: 0 }}>
        <CartesianGrid stroke={LINE} vertical={false} />
        <XAxis dataKey="label" tick={{ fill: FAINT, fontSize: 11 }} tickLine={false} axisLine={{ stroke: LINE }} interval="preserveStartEnd" />
        <YAxis tick={{ fill: FAINT, fontSize: 11 }} tickLine={false} axisLine={false} width={40} />
        <Tooltip content={<Tip fmt={fmt} />} cursor={{ fill: 'rgba(0,49,61,.04)' }} />
        <Bar dataKey="value" name="Conversões" fill={color} radius={[4, 4, 0, 0]} maxBarSize={40} />
      </BarChart>
    </ResponsiveContainer>
  )
}
