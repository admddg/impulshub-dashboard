'use client'

import { useEffect, useState, useCallback } from 'react'
import {
  fetchTracking, type TrackingRow, type OverallStatus,
} from '@/lib/agency'
import { getMyClients, type ClientAccess } from '@/lib/access'
import { getRanges, dataDeCorteLabel, type Period, type CustomRange } from '@/lib/utils'
import PeriodSelector from '@/components/PeriodSelector'
import TrackingDrawer from '@/components/agencia/TrackingDrawer'
import { quando, numero, TRACO } from '@/components/agencia/format'

const POR_PAGINA = 100

const STATUS_GERAL: { id: OverallStatus; label: string }[] = [
  { id: 'ok', label: 'OK' },
  { id: 'processing', label: 'Em andamento' },
  { id: 'warning', label: 'Atenção' },
  { id: 'inconsistent', label: 'Inconsistente' },
  { id: 'error', label: 'Erro' },
]

const ROTULO_OVERALL: Record<string, string> = {
  ok: 'OK', warning: 'Atenção', processing: 'Em andamento',
  inconsistent: 'Inconsistente', error: 'Erro',
}

// Mapeia o status de cada etapa para um dos três ícones: cumpriu, não se
// aplica, ou travou/falhou. Aqui NÃO recalculamos o status geral — só damos
// uma leitura visual da etapa. O overall_status do banco continua sendo a
// verdade.
function iconeEtapa(status: string | null | undefined): 'ok' | 'na' | 'bad' | 'wait' {
  if (!status) return 'na'
  const s = status.toLowerCase()
  if (['ok', 'sent', 'normalized', 'processed', 'applicable', 'success', 'completed'].some((k) => s.includes(k))) return 'ok'
  if (['not_applicable', 'skipped', 'na'].some((k) => s.includes(k))) return 'na'
  if (['error', 'failed', 'stuck', 'inconsistent', 'not_recorded', 'missing', 'not_closed'].some((k) => s.includes(k))) return 'bad'
  if (['pending', 'processing', 'running'].some((k) => s.includes(k))) return 'wait'
  return 'ok'
}

function Passo({ status }: { status: string | null | undefined }) {
  const t = iconeEtapa(status)
  const glifo = t === 'ok' ? '✓' : t === 'bad' ? '✕' : t === 'wait' ? '⋯' : '–'
  return <span className={`ag-step ag-step-${t}`} title={status ?? 'sem dado'}>{glifo}</span>
}

export default function TrackingPage() {
  const [period, setPeriod] = useState<Period>('15d')
  const [custom, setCustom] = useState<CustomRange | null>(null)
  const [status, setStatus] = useState<OverallStatus | null>(null)
  const [clienteId, setClienteId] = useState<string | null>(null)
  const [busca, setBusca] = useState('')
  const [buscaAplicada, setBuscaAplicada] = useState('')
  const [pagina, setPagina] = useState(0)

  const [clientes, setClientes] = useState<ClientAccess[]>([])
  const [rows, setRows] = useState<TrackingRow[]>([])
  const [total, setTotal] = useState<number | null>(null)
  const [carregando, setCarregando] = useState(true)
  const [erro, setErro] = useState<string | null>(null)
  const [aberto, setAberto] = useState<TrackingRow | null>(null)

  useEffect(() => { getMyClients().then(setClientes) }, [])

  useEffect(() => {
    const t = setTimeout(() => { setBuscaAplicada(busca); setPagina(0) }, 400)
    return () => clearTimeout(t)
  }, [busca])

  useEffect(() => { setPagina(0) }, [period, custom, status, clienteId])

  const carregar = useCallback(() => {
    let vivo = true
    setCarregando(true)
    setErro(null)
    const { start, end } = getRanges(period, custom ?? undefined).current

    fetchTracking({
      start, end, clientId: clienteId, status,
      search: buscaAplicada, limit: POR_PAGINA, offset: pagina * POR_PAGINA,
    }).then(({ rows, total, error }) => {
      if (!vivo) return
      if (error) { setErro(error); setCarregando(false); return }
      setRows(rows); setTotal(total); setCarregando(false)
    })
    return () => { vivo = false }
  }, [period, custom, clienteId, status, buscaAplicada, pagina])

  useEffect(() => carregar(), [carregar])

  const totalPaginas = total !== null ? Math.max(1, Math.ceil(total / POR_PAGINA)) : 1
  const temMais = total !== null && (pagina + 1) * POR_PAGINA < total

  return (
    <>
      <div className="pagehead tight">
        <div>
          <h1>Eventos e tracking</h1>
          <div className="sub">Cada evento, do recebimento ao resultado na plataforma — Dados até {dataDeCorteLabel()}</div>
        </div>
        <PeriodSelector period={period} custom={custom} onChange={(p, c) => { setPeriod(p); setCustom(c ?? null) }} />
      </div>

      <div className="ag-summary">
        <button className={`ag-sum ${status === null ? 'active' : ''}`} onClick={() => setStatus(null)}>
          <span className="ag-sum-num">{numero(total)}</span>
          <span className="ag-sum-label">No período</span>
        </button>
        {STATUS_GERAL.map((st) => (
          <button
            key={st.id}
            className={`ag-sum h-${st.id} ${status === st.id ? 'active' : ''}`}
            onClick={() => setStatus(status === st.id ? null : st.id)}
          >
            <span className="ag-sum-label" style={{ fontWeight: 600 }}>{st.label}</span>
          </button>
        ))}
      </div>

      <div className="ag-toolbar">
        <div className="ag-search">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
            <circle cx="11" cy="11" r="8" /><path d="m21 21-4.35-4.35" />
          </svg>
          <input type="search" placeholder="Buscar por contato, evento ou ID do contato"
            value={busca} onChange={(e) => setBusca(e.target.value)} />
        </div>
        <div className="ag-toolbar-right">
          <select className="select-native" value={clienteId ?? 'all'}
            onChange={(e) => setClienteId(e.target.value === 'all' ? null : e.target.value)}>
            <option value="all">Todos os clientes</option>
            {clientes.map((c) => <option key={c.client_id} value={c.client_id}>{c.client_name}</option>)}
          </select>
        </div>
      </div>

      {carregando && <div className="state"><div className="spinner" />Carregando eventos…</div>}

      {!carregando && erro && (
        <div className="state" style={{ flexDirection: 'column', gap: 12 }}>
          <span style={{ color: 'var(--ink-soft)', fontSize: 14 }}>Não foi possível carregar o tracking.</span>
          <button className="sortbtn" style={{ border: '1px solid var(--line)' }} onClick={carregar}>Tentar novamente</button>
        </div>
      )}

      {!carregando && !erro && rows.length === 0 && (
        <div className="table-empty">Nenhum evento com esses filtros no período.</div>
      )}

      {!carregando && !erro && rows.length > 0 && (
        <>
          <div className="ag-track-wrap">
            <table className="ag-track">
              <thead>
                <tr>
                  <th>Evento</th>
                  <th>Contato</th>
                  <th className="ag-track-steps-h" colSpan={5}>Jornada</th>
                  <th>Status</th>
                  <th>Quando</th>
                </tr>
                <tr className="ag-track-substeps">
                  <th></th><th></th>
                  <th>Rec.</th><th>Norm.</th><th>Rota</th><th>Conv.</th><th>n8n</th>
                  <th></th><th></th>
                </tr>
              </thead>
              <tbody>
                {rows.map((r) => (
                  <tr key={r.raw_event_id} onClick={() => setAberto(r)} className="ag-track-row">
                    <td className="ag-track-evt">{r.event_code ?? TRACO}</td>
                    <td className="ag-track-contact">{r.full_name || <span className="cell-muted">{TRACO}</span>}</td>
                    <td className="ag-track-step"><Passo status={r.raw_audit_status} /></td>
                    <td className="ag-track-step"><Passo status={r.normalization_audit_status ?? r.normalization_status} /></td>
                    <td className="ag-track-step"><Passo status={r.conversion_applicability} /></td>
                    <td className="ag-track-step"><Passo status={r.conversion_summary_status} /></td>
                    <td className="ag-track-step"><Passo status={r.inbound_n8n_status} /></td>
                    <td><span className={`ag-health h-${r.overall_status}`}>{ROTULO_OVERALL[r.overall_status] ?? r.overall_status}</span></td>
                    <td className="ag-track-when">{quando(r.received_at)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          <div className="pager">
            <div className="pager-info">
              {pagina * POR_PAGINA + 1}–{pagina * POR_PAGINA + rows.length} de {numero(total)}
            </div>
            <div className="pager-btns">
              <button className="pager-page" disabled={pagina === 0} onClick={() => setPagina((p) => Math.max(0, p - 1))}>Anterior</button>
              <span className="pager-info">{pagina + 1} / {totalPaginas}</span>
              <button className="pager-page" disabled={!temMais} onClick={() => setPagina((p) => p + 1)}>Próxima</button>
            </div>
          </div>
        </>
      )}

      {aberto && <TrackingDrawer row={aberto} onClose={() => setAberto(null)} />}
    </>
  )
}
