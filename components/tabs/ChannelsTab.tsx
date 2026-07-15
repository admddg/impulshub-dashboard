'use client'

import { useEffect, useState } from 'react'
import { fetchWindowed, splitByDate } from '@/lib/data'
import {
  num, int, channelBucket, channelColor, CHANNEL_ORDER,
  entradaBucket, entradaColor, ENTRADA_ORDER, type Period, type CustomRange,
} from '@/lib/utils'
import { HBarChart } from '@/components/Charts'
import DataTable, { type Column } from '@/components/DataTable'

type CrossRow = { entrada: string; [origem: string]: string | number }

export default function ChannelsTab({ clientId, period, custom }: { clientId: string; period: Period; periodLabel: string; custom: CustomRange | null }) {
  const [loading, setLoading] = useState(true)
  const [porOrigem, setPorOrigem] = useState<{ label: string; value: number; color: string }[]>([])
  const [porEntrada, setPorEntrada] = useState<{ label: string; value: number; color: string }[]>([])
  const [cross, setCross] = useState<CrossRow[]>([])
  const [origensPresentes, setOrigensPresentes] = useState<string[]>([])

  useEffect(() => {
    let alive = true
    setLoading(true)
    // consome contagens já agregadas no banco (por dia + combinação de
    // valores crus) — evita o mesmo risco de truncamento que o v_client_daily_pulse resolveu
    fetchWindowed('v_client_lead_channel_daily', 'date, lead_entrada, lead_origem, channel_source, leads', period, clientId, 'date', custom ?? undefined)
      .then(({ rows, current, previous }) => {
        if (!alive) return
        const leads = splitByDate(rows, current, previous).cur

        // por origem (canal)
        const origemMap = new Map<string, number>()
        // por entrada
        const entradaMap = new Map<string, number>()
        // cruzamento entrada x origem
        const crossMap = new Map<string, Map<string, number>>()

        for (const r of leads) {
          const origem = channelBucket(r.lead_origem ?? r.channel_source)
          const entrada = entradaBucket(r.lead_entrada)
          const n = num(r.leads)
          origemMap.set(origem, (origemMap.get(origem) ?? 0) + n)
          entradaMap.set(entrada, (entradaMap.get(entrada) ?? 0) + n)
          if (!crossMap.has(entrada)) crossMap.set(entrada, new Map())
          const c = crossMap.get(entrada)!
          c.set(origem, (c.get(origem) ?? 0) + n)
        }

        setPorOrigem(CHANNEL_ORDER.filter((o) => origemMap.has(o)).map((o) => ({ label: o, value: origemMap.get(o)!, color: channelColor(o) })))
        setPorEntrada(ENTRADA_ORDER.filter((e) => entradaMap.has(e)).map((e) => ({ label: e, value: entradaMap.get(e)!, color: entradaColor(e) })))

        // monta tabela cruzada
        const origens = CHANNEL_ORDER.filter((o) => origemMap.has(o))
        setOrigensPresentes(origens)
        const crossRows: CrossRow[] = ENTRADA_ORDER.filter((e) => crossMap.has(e)).map((entrada) => {
          const row: CrossRow = { entrada }
          let tot = 0
          for (const o of origens) { const v = crossMap.get(entrada)?.get(o) ?? 0; row[o] = v; tot += v }
          row.total = tot
          return row
        })
        setCross(crossRows)
        setLoading(false)
      })
    return () => { alive = false }
  }, [clientId, period, custom])

  if (loading) return <div className="state"><div className="spinner" />Carregando canais…</div>

  // colunas da tabela cruzada: Entrada | <cada origem> | Total
  const crossCols: Column<CrossRow>[] = [
    { key: 'entrada', header: 'Entrada \\ Origem', render: (r) => <span className="cell-strong">{r.entrada}</span>, width: 150 },
    ...origensPresentes.map((o) => ({
      key: o, header: o, align: 'right' as const,
      render: (r: CrossRow) => (r[o] as number) > 0 ? int(r[o] as number) : <span className="cell-muted">—</span>,
      sortValue: (r: CrossRow) => r[o] as number,
    })),
    { key: 'total', header: 'Total', align: 'right' as const, render: (r) => <span className="cell-strong">{int(r.total as number)}</span>, sortValue: (r) => r.total as number },
  ]

  // total geral
  const totalRow: Record<string, React.ReactNode> = { entrada: 'Total' }
  let grand = 0
  for (const o of origensPresentes) { const s = cross.reduce((a, r) => a + (r[o] as number), 0); totalRow[o] = int(s); grand += s }
  totalRow.total = int(grand)

  return (
    <>
      <div className="grid-2">
        <div className="block">
          <div className="block-head"><span className="block-title">Leads por Entrada</span><span className="block-sub">Por onde o lead chegou</span></div>
          <HBarChart data={porEntrada} fmt={(v) => int(v)} height={Math.max(porEntrada.length * 44, 120)} />
        </div>
        <div className="block">
          <div className="block-head"><span className="block-title">Leads por Origem</span><span className="block-sub">De qual canal veio</span></div>
          <HBarChart data={porOrigem} fmt={(v) => int(v)} height={Math.max(porOrigem.length * 44, 120)} />
        </div>
      </div>

      <div className="block-head" style={{ marginBottom: 12 }}><span className="block-title">Entrada × Origem</span><span className="block-sub">Cruzamento: por onde entrou vs. canal de origem</span></div>
      <DataTable columns={crossCols} rows={cross} totalRow={totalRow} />

      <div className="muted-note">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><circle cx="12" cy="12" r="10" /><path d="M12 16v-4M12 8h.01" /></svg>
        <strong style={{ fontWeight: 600 }}>Entrada</strong> é por onde o lead chegou (WhatsApp, Site, Formulário). <strong style={{ fontWeight: 600 }}>Origem</strong> é o canal que trouxe (Meta, Google, Orgânico).
      </div>
    </>
  )
}
