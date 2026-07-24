'use client'

import { useEffect, useMemo, useState, useCallback } from 'react'
import { fetchSyncHealth, type SyncRow, type SyncHealthStatus } from '@/lib/agency'
import { dataDeCorteLabel } from '@/lib/utils'
import { quando, duracao, numero, TRACO } from '@/components/agencia/format'

// Semântica de cor pedida pelo documento de banco. completed_no_data e
// backfill_completed são SAUDÁVEIS (não erro). telemetry_not_closed é atenção
// (log aberto), não falha real.
const SAUDE: Record<SyncHealthStatus, { label: string; cls: string }> = {
  ok: { label: 'OK', cls: 'h-ok' },
  completed_no_data: { label: 'Sem dados no período', cls: 'h-info' },
  backfill_completed: { label: 'Backfill concluído', cls: 'h-ok' },
  running: { label: 'Em execução', cls: 'h-pending' },
  telemetry_not_closed: { label: 'Log não encerrado', cls: 'h-warning' },
  error: { label: 'Erro', cls: 'h-error' },
  not_run: { label: 'Não executou', cls: 'h-pending' },
}

const PLATAFORMAS = [
  { key: 'meta', label: 'Meta' },
  { key: 'google', label: 'Google' },
  { key: 'google_ads', label: 'Google' },
]

function rotuloPlataforma(p: string) {
  return PLATAFORMAS.find((x) => x.key === p)?.label ?? p
}

function Celula({ row, onClick }: { row: SyncRow | undefined; onClick: () => void }) {
  if (!row) return <td className="ag-mx-cell is-absent"><span className="cell-muted">{TRACO}</span></td>
  const s = SAUDE[row.health_status] ?? { label: row.health_status, cls: 'h-info' }
  return (
    <td className="ag-mx-cell">
      <button className="ag-mx-btn" onClick={onClick}>
        <span className={`ag-health ${s.cls}`}>{s.label}</span>
        <span className="ag-mx-when">{quando(row.last_finished_at ?? row.last_attempt_at)}</span>
      </button>
    </td>
  )
}

export default function SyncPage() {
  const [modo, setModo] = useState<'daily' | 'backfill'>('daily')
  const [rows, setRows] = useState<SyncRow[]>([])
  const [carregando, setCarregando] = useState(true)
  const [erro, setErro] = useState<string | null>(null)
  const [aberto, setAberto] = useState<SyncRow | null>(null)

  const carregar = useCallback(() => {
    let vivo = true
    setCarregando(true)
    setErro(null)
    fetchSyncHealth().then(({ rows, error }) => {
      if (!vivo) return
      if (error) { setErro(error); setCarregando(false); return }
      setRows(rows); setCarregando(false)
    })
    return () => { vivo = false }
  }, [])

  useEffect(() => carregar(), [carregar])

  // Não somar Daily e Backfill no mesmo quadro. O modo escolhe o universo.
  const filtradas = useMemo(
    () => rows.filter((r) => r.operation_type === modo),
    [rows, modo]
  )

  // Monta a matriz: uma linha por cliente, uma coluna por plataforma.
  const { clientes, plataformas, celula } = useMemo(() => {
    const mapaCli = new Map<string, string>()
    const setPlat = new Set<string>()
    const cel = new Map<string, SyncRow>()
    for (const r of filtradas) {
      mapaCli.set(r.client_id, r.client_name ?? r.client_slug ?? r.client_id)
      setPlat.add(r.platform)
      cel.set(`${r.client_id}|${r.platform}`, r)
    }
    return {
      clientes: [...mapaCli.entries()].map(([id, nome]) => ({ id, nome })).sort((a, b) => a.nome.localeCompare(b.nome)),
      plataformas: [...setPlat].sort(),
      celula: cel,
    }
  }, [filtradas])

  // Contadores do topo, no universo do modo ativo.
  const resumo = useMemo(() => {
    const c = { problema: 0, saudavel: 0, atencao: 0 }
    for (const r of filtradas) {
      if (r.health_status === 'error') c.problema++
      else if (r.health_status === 'telemetry_not_closed') c.atencao++
      else c.saudavel++
    }
    return c
  }, [filtradas])

  return (
    <>
      <div className="pagehead tight">
        <div>
          <h1>Sync</h1>
          <div className="sub">Estado atual da sincronização por cliente e plataforma — Dados até {dataDeCorteLabel()}</div>
        </div>
      </div>

      <div className="tabs">
        <button className={`tab ${modo === 'daily' ? 'active' : ''}`} onClick={() => setModo('daily')}>Diário</button>
        <button className={`tab ${modo === 'backfill' ? 'active' : ''}`} onClick={() => setModo('backfill')}>Backfill</button>
      </div>

      {!carregando && !erro && (
        <div className="ag-summary" style={{ marginTop: 4 }}>
          <div className="ag-sum h-ok"><span className="ag-sum-num">{numero(resumo.saudavel)}</span><span className="ag-sum-label">Saudáveis</span></div>
          <div className="ag-sum h-warning"><span className="ag-sum-num">{numero(resumo.atencao)}</span><span className="ag-sum-label">Log aberto</span></div>
          <div className="ag-sum h-error"><span className="ag-sum-num">{numero(resumo.problema)}</span><span className="ag-sum-label">Com erro</span></div>
        </div>
      )}

      {carregando && <div className="state"><div className="spinner" />Carregando saúde de sync…</div>}

      {!carregando && erro && (
        <div className="state" style={{ flexDirection: 'column', gap: 12 }}>
          <span style={{ color: 'var(--ink-soft)', fontSize: 14 }}>Não foi possível carregar a saúde de sync.</span>
          <button className="sortbtn" style={{ border: '1px solid var(--line)' }} onClick={carregar}>Tentar novamente</button>
        </div>
      )}

      {!carregando && !erro && clientes.length === 0 && (
        <div className="table-empty">Nenhuma operação de {modo === 'daily' ? 'sincronização diária' : 'backfill'} registrada.</div>
      )}

      {!carregando && !erro && clientes.length > 0 && (
        <div className="ag-mx-wrap">
          <table className="ag-mx">
            <thead>
              <tr>
                <th className="ag-mx-cli-h">Cliente</th>
                {plataformas.map((p) => <th key={p}>{rotuloPlataforma(p)}</th>)}
              </tr>
            </thead>
            <tbody>
              {clientes.map((cli) => (
                <tr key={cli.id}>
                  <td className="ag-mx-cli">{cli.nome}</td>
                  {plataformas.map((p) => (
                    <Celula
                      key={p}
                      row={celula.get(`${cli.id}|${p}`)}
                      onClick={() => { const r = celula.get(`${cli.id}|${p}`); if (r) setAberto(r) }}
                    />
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {aberto && (
        <div className="ag-drawer-backdrop" onClick={() => setAberto(null)}>
          <aside className="ag-drawer" onClick={(e) => e.stopPropagation()} role="dialog" aria-modal="true">
            <div className="ag-drawer-top">
              <div>
                <div className="ag-drawer-title">{aberto.client_name}</div>
                <div className="ag-drawer-sub">{rotuloPlataforma(aberto.platform)} · {aberto.operation_type === 'daily' ? 'Sincronização diária' : 'Backfill'}</div>
              </div>
              <button className="ag-drawer-close" onClick={() => setAberto(null)} aria-label="Fechar">×</button>
            </div>

            <div className={`ag-drawer-overall ${SAUDE[aberto.health_status]?.cls ?? 'h-info'}`}>
              <span className="ag-drawer-overall-badge">{SAUDE[aberto.health_status]?.label ?? aberto.health_status}</span>
              {aberto.health_reason && <span className="ag-drawer-overall-reason">{aberto.health_reason}</span>}
            </div>

            <div className="ag-drawer-section">Última execução</div>
            <div className="ag-drawer-kv">
              <div><span>Status técnico</span><b>{aberto.last_status ?? TRACO}</b></div>
              <div><span>Checkpoint</span><b>{aberto.last_checkpoint ?? TRACO}</b></div>
              <div><span>Tentativa</span><b>{quando(aberto.last_attempt_at)}</b></div>
              <div><span>Sucesso</span><b>{quando(aberto.last_success_at)}</b></div>
              <div><span>Duração</span><b>{duracao(aberto.duration_ms)}</b></div>
              <div><span>Processados</span><b>{numero(aberto.items_processed)}</b></div>
              <div><span>Falhas</span><b>{numero(aberto.items_failed)}</b></div>
              <div><span>Última escrita física</span><b>{quando(aberto.last_physical_write_at)}</b></div>
              <div><span>Data máx. do dado</span><b>{aberto.max_data_date ?? TRACO}</b></div>
            </div>

            {aberto.last_error_message && (
              <>
                <div className="ag-drawer-section">Erro técnico</div>
                <div className="ag-job-err">{aberto.last_error_message}</div>
                {aberto.last_error_node && <div className="ag-drawer-sub" style={{ marginTop: 6 }}>Node: {aberto.last_error_node}</div>}
              </>
            )}
          </aside>
        </div>
      )}
    </>
  )
}
