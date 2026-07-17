'use client'

import { useEffect, useState } from 'react'
import { fetchWindowed, splitByDate } from '@/lib/data'
import { num, int, type Period, type CustomRange } from '@/lib/utils'
import { HBarChart } from '@/components/Charts'

type Bar = { label: string; value: number; color: string }

// Paleta oficial Impuls — petrol/mint/variações
const IMPULS_PALETTE = ['#00313d', '#5fae95', '#94d2bd', '#546069', '#002832', '#8794a0']
function colorFor(label: string) {
  if (label === 'Meta Ads') return '#00313d'
  if (label === 'Google Ads') return '#5fae95'
  if (label === 'Não atribuído' || label === 'Não informado') return '#8794a0'
  if (label === 'Conflito') return '#546069'
  let h = 0
  for (let i = 0; i < label.length; i++) h = (h * 31 + label.charCodeAt(i)) >>> 0
  return IMPULS_PALETTE[h % IMPULS_PALETTE.length]
}

// "Revisar" é ruído para o cliente — omitido até o banco unificar com "Não informado"
const OMIT_VALUES = new Set(['Revisar'])

function toBars(rows: any[], dimType: string): Bar[] {
  const map = new Map<string, number>()
  for (const r of rows) {
    if (r.dimension_type !== dimType) continue
    if (OMIT_VALUES.has(r.dimension_value)) continue
    map.set(r.dimension_value, (map.get(r.dimension_value) ?? 0) + num(r.crm_leads))
  }
  return [...map.entries()].sort((a, b) => b[1] - a[1])
    .map(([label, value]) => ({ label, value, color: colorFor(label) }))
}

export default function ChannelsTab({ clientId, period, custom }: {
  clientId: string; period: Period; periodLabel: string; custom: CustomRange | null
}) {
  const [loading, setLoading] = useState(true)
  const [tecnica, setTecnica] = useState<Bar[]>([])
  const [entrada, setEntrada] = useState<Bar[]>([])
  const [origem, setOrigem] = useState<Bar[]>([])

  useEffect(() => {
    let alive = true
    setLoading(true)
    fetchWindowed('v_crm_channels_daily_v2', 'date, dimension_type, dimension_value, crm_leads',
      period, clientId, 'date', custom ?? undefined
    ).then(({ rows, current, previous }) => {
      if (!alive) return
      const cur = splitByDate(rows, current, previous).cur
      setTecnica(toBars(cur, 'plataforma_atribuida'))
      setEntrada(toBars(cur, 'entrada_informada'))
      setOrigem(toBars(cur, 'origem_informada'))
      setLoading(false)
    })
    return () => { alive = false }
  }, [clientId, period, custom])

  if (loading) return <div className="state"><div className="spinner" />Carregando canais…</div>

  return (
    <>
      <div className="block">
        <div className="block-head">
          <span className="block-title">Atribuição técnica</span>
          <span className="block-sub">Metodologia oficial — identificador técnico de anúncio (meta_ad_id / IDs Google)</span>
        </div>
        <HBarChart data={tecnica} fmt={(v) => int(v)} height={Math.max(tecnica.length * 44, 100)} />
      </div>

      <div className="grid-2">
        <div className="block">
          <div className="block-head">
            <span className="block-title">Entrada informada</span>
            <span className="block-sub">Dado bruto — por onde o lead entrou</span>
          </div>
          <HBarChart data={entrada} fmt={(v) => int(v)} height={Math.max(entrada.length * 44, 100)} />
        </div>
        <div className="block">
          <div className="block-head">
            <span className="block-title">Origem informada</span>
            <span className="block-sub">Dado bruto — de onde veio segundo o CRM</span>
          </div>
          <HBarChart data={origem} fmt={(v) => int(v)} height={Math.max(origem.length * 44, 100)} />
        </div>
      </div>

      <div className="muted-note">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><circle cx="12" cy="12" r="10" /><path d="M12 16v-4M12 8h.01" /></svg>
        <strong style={{ fontWeight: 600 }}>Atribuição técnica</strong> é a fonte confiável (nunca inferida por texto). <strong style={{ fontWeight: 600 }}>Entrada</strong> e <strong style={{ fontWeight: 600 }}>Origem</strong> são campos brutos do CRM — complementares, não substituem a atribuição técnica.
      </div>
    </>
  )
}
