'use client'

import { Suspense, useEffect, useMemo, useState, useCallback } from 'react'
import { useRouter, useSearchParams } from 'next/navigation'
import {
  fetchAgencyOverview, STATUS_DO_CARD,
  type AgencyOverview, type AgencyClientRow, type SortBy,
} from '@/lib/agency'
import { getRanges, dataDeCorteLabel, type Period, type CustomRange } from '@/lib/utils'
import PeriodSelector from '@/components/PeriodSelector'
import DataTable, { type Column } from '@/components/DataTable'
import { dinheiro, dinheiroPreciso, numero, multiplicador, TRACO } from '@/components/agencia/format'

const CARDS_DE_QUALIDADE: { chave: string; label: string; campo: keyof AgencyOverview['quality'] }[] = [
  { chave: 'ok', label: 'Sem pendência', campo: 'ok_clients' },
  { chave: 'setup_pending', label: 'Setup pendente', campo: 'setup_pending_clients' },
  { chave: 'investment_incomplete', label: 'Investimento incompleto', campo: 'investment_incomplete_clients' },
  { chave: 'revenue_incomplete', label: 'Receita incompleta', campo: 'revenue_incomplete_clients' },
  { chave: 'attribution_conflict', label: 'Conflito de atribuição', campo: 'attribution_conflict_clients' },
]

const ROTULO_SITUACAO: Record<string, string> = {
  ok: 'Sem pendência',
  setup_pending: 'Setup pendente',
  investment_incomplete: 'Investimento incompleto',
  revenue_incomplete: 'Receita incompleta',
  acquisition_revenue_incomplete: 'Receita de aquisição incompleta',
  attribution_conflict: 'Conflito de atribuição',
}

const TOOLTIP_ROAS = 'O ROAS não pode ser calculado porque a receita de aquisição do período está incompleta.'

function OverviewInterno() {
  const router = useRouter()
  const searchParams = useSearchParams()
  const situacaoDaUrl = searchParams.get('situacao')

  const [period, setPeriod] = useState<Period>('30d')
  const [custom, setCustom] = useState<CustomRange | null>(null)
  const [busca, setBusca] = useState('')
  const [buscaAplicada, setBuscaAplicada] = useState('')
  const [ordem, setOrdem] = useState<SortBy>('investment')
  const [situacao, setSituacao] = useState<string | null>(situacaoDaUrl)

  const [dados, setDados] = useState<AgencyOverview | null>(null)
  const [carregando, setCarregando] = useState(true)
  const [erro, setErro] = useState<string | null>(null)

  useEffect(() => {
    const t = setTimeout(() => setBuscaAplicada(busca), 400)
    return () => clearTimeout(t)
  }, [busca])

  useEffect(() => { setSituacao(situacaoDaUrl) }, [situacaoDaUrl])

  const carregar = useCallback(() => {
    let vivo = true
    setCarregando(true)
    setErro(null)
    const { start, end } = getRanges(period, custom ?? undefined).current

    fetchAgencyOverview({
      start, end, search: buscaAplicada, sortBy: ordem,
      sortDirection: ordem === 'client_name' ? 'asc' : 'desc',
    }).then(({ data, error }) => {
      if (!vivo) return
      if (error) { setErro(error); setCarregando(false); return }
      setDados(data)
      setCarregando(false)
    })
    return () => { vivo = false }
  }, [period, custom, buscaAplicada, ordem])

  useEffect(() => carregar(), [carregar])

  const clientes = useMemo(() => {
    const todos = dados?.clients ?? []
    if (!situacao) return todos
    const aceitos = STATUS_DO_CARD[situacao]
    if (!aceitos) return todos
    return todos.filter((c) => aceitos.includes(c.quality_status))
  }, [dados, situacao])

  function abrir(c: AgencyClientRow) {
    router.push(`/clientes/${c.client_slug}/dashboard`)
  }

  const p = dados?.portfolio
  const q = dados?.quality

  const colunas: Column<AgencyClientRow>[] = [
    { key: 'nome', header: 'Cliente', width: 190,
      render: (c) => <button className="ag-link-cell" onClick={() => abrir(c)}>{c.client_name}</button>,
      sortValue: (c) => c.client_name },
    { key: 'situacao', header: 'Situação',
      render: (c) => (
        <span className={`ag-pill st-${c.quality_status}`}>
          {ROTULO_SITUACAO[c.quality_status] ?? c.quality_status}
        </span>
      ),
      sortValue: (c) => c.quality_status },
    { key: 'inv', header: 'Investimento', align: 'right',
      render: (c) => dinheiro(c.investment, c.investment_is_complete),
      sortValue: (c) => c.investment ?? -1 },
    { key: 'leads', header: 'Leads', align: 'right',
      render: (c) => numero(c.leads), sortValue: (c) => c.leads ?? -1 },
    { key: 'agend', header: 'Agendam.', align: 'right',
      render: (c) => numero(c.agendados), sortValue: (c) => c.agendados ?? -1 },
    { key: 'ganhos', header: 'Ganhos', align: 'right',
      render: (c) => numero(c.crm_ganhos), sortValue: (c) => c.crm_ganhos ?? -1 },
    { key: 'cpl', header: 'CPL', align: 'right',
      render: (c) => dinheiroPreciso(c.cpl_paid), sortValue: (c) => c.cpl_paid ?? -1 },
    { key: 'roas', header: 'ROAS', align: 'right',
      tooltip: TOOLTIP_ROAS,
      render: (c) => c.roas_acquisition === null
        ? <span className="cell-muted" title={TOOLTIP_ROAS}>{TRACO}</span>
        : multiplicador(c.roas_acquisition),
      sortValue: (c) => c.roas_acquisition ?? -1 },
  ]

  return (
    <>
      <div className="pagehead tight">
        <div>
          <h1>Overview da agência</h1>
          <div className="sub">Carteira consolidada — Dados até {dataDeCorteLabel()}</div>
        </div>
        <PeriodSelector period={period} custom={custom} onChange={(pp, c) => { setPeriod(pp); setCustom(c ?? null) }} />
      </div>

      {carregando && <div className="state"><div className="spinner" />Carregando portfólio…</div>}

      {!carregando && erro && (
        <div className="state" style={{ flexDirection: 'column', gap: 12 }}>
          <span style={{ color: 'var(--ink-soft)', fontSize: 14 }}>Não foi possível carregar o portfólio.</span>
          <button className="sortbtn" style={{ border: '1px solid var(--line)' }} onClick={carregar}>Tentar novamente</button>
        </div>
      )}

      {!carregando && !erro && p && (
        <>
          <div className="kpi-grid ag-kpis">
            <div className="kpi primary">
              <div className="kpi-label">Investimento</div>
              <div className="kpi-value">{dinheiro(p.investment, p.investment_is_complete)}</div>
            </div>
            <div className="kpi">
              <div className="kpi-label">Leads</div>
              <div className="kpi-value">{numero(p.leads)}</div>
            </div>
            <div className="kpi">
              <div className="kpi-label">Agendamentos</div>
              <div className="kpi-value">{numero(p.agendados)}</div>
            </div>
            <div className="kpi">
              <div className="kpi-label">CPL</div>
              <div className="kpi-value">{dinheiroPreciso(p.cpl_paid)}</div>
            </div>
          </div>

          <div className="block-head" style={{ marginBottom: 12, marginTop: 4 }}>
            <span className="block-title">Qualidade da carteira</span>
            <span className="block-sub">Clique para filtrar a lista abaixo</span>
          </div>

          <div className="ag-quality">
            {q && CARDS_DE_QUALIDADE.map((c) => {
              const ativo = situacao === c.chave
              return (
                <button
                  key={c.chave}
                  className={`ag-quality-card ${c.chave === 'ok' ? 'is-ok' : ''} ${q[c.campo] === 0 ? 'is-empty' : ''} ${ativo ? 'is-active' : ''}`}
                  onClick={() => setSituacao(ativo ? null : c.chave)}
                >
                  <span className="ag-quality-num">{numero(q[c.campo])}</span>
                  <span className="ag-quality-label">{c.label}</span>
                </button>
              )
            })}
          </div>

          <div className="ag-toolbar" style={{ marginTop: 20 }}>
            <div className="ag-search">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
                <circle cx="11" cy="11" r="8" /><path d="m21 21-4.35-4.35" />
              </svg>
              <input
                type="search"
                placeholder="Buscar cliente por nome ou slug"
                value={busca}
                onChange={(e) => setBusca(e.target.value)}
              />
            </div>
            {situacao && (
              <div className="ag-filter-chip">
                {ROTULO_SITUACAO[situacao] ?? situacao}
                <button onClick={() => setSituacao(null)}>Limpar</button>
              </div>
            )}
          </div>

          {clientes.length === 0 ? (
            <div className="table-empty">Nenhum cliente encontrado com esses filtros.</div>
          ) : (
            <DataTable columns={colunas} rows={clientes} initialSort={{ key: 'inv', dir: 'desc' }} />
          )}

          <div className="muted-note">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
              <circle cx="12" cy="12" r="10" /><path d="M12 16v-4M12 8h.01" />
            </svg>
            Indicadores calculados no banco, a partir da mesma função que alimenta
            cada painel de cliente. {TRACO} significa dado incompleto, não zero.
            &quot;Receita pendente&quot; no ROAS: existe ganho, mas a receita de
            aquisição do período ainda não está completa.
          </div>
        </>
      )}
    </>
  )
}

export default function AgenciaOverviewPage() {
  return (
    <Suspense fallback={<div className="state"><div className="spinner" />Carregando…</div>}>
      <OverviewInterno />
    </Suspense>
  )
}
