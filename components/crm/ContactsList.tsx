'use client'

import { useEffect, useState } from 'react'
import {
  fetchContacts, fetchCard, fmtDataCurta, fmtTelefone, classeEtapa, temFiltro,
  TAMANHO_PAGINA_CONTATOS,
  type CrmContact, type CrmCard, type CrmFiltros,
} from '@/lib/crm'

// Lista de contatos com busca. A busca roda no banco, sobre `search_text`,
// que a view já entrega pronto — não é filtro sobre a página carregada, que
// daria resultado errado a partir do contato 51.

export default function ContactsList({
  clientId, filtros, onOpen, onAviso,
}: {
  clientId: string
  filtros: CrmFiltros
  onOpen: (card: CrmCard) => void
  onAviso: (msg: string) => void
}) {
  const [digitado, setDigitado] = useState('')
  const [busca, setBusca] = useState('')
  const [rows, setRows] = useState<CrmContact[]>([])
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(0)
  const [carregando, setCarregando] = useState(true)
  const [falhou, setFalhou] = useState(false)

  // Espera a digitação parar antes de ir ao banco. Sem isso, "Maria" são
  // cinco requests e a última a responder pode não ser a última digitada.
  useEffect(() => {
    const t = setTimeout(() => setBusca(digitado), 300)
    return () => clearTimeout(t)
  }, [digitado])

  // Trocar filtro ou busca volta para a primeira pagina: manter o offset
  // mostraria a pagina 3 de um recorte que agora tem uma pagina so.
  useEffect(() => { setPage(0) }, [clientId, busca, filtros])

  useEffect(() => {
    let alive = true
    setCarregando(true)
    fetchContacts(clientId, busca, page, TAMANHO_PAGINA_CONTATOS, filtros).then(({ rows, total, erro }) => {
      if (!alive) return
      setRows(rows)
      setTotal(total)
      setFalhou(!!erro)
      setCarregando(false)
    })
    return () => { alive = false }
  }, [clientId, busca, page, filtros])

  // A lista é de contatos; o card é da oportunidade. Contato sem oportunidade
  // não tem card para abrir — é gente que conversou mas não teve entrada
  // comercial, e isso é de propósito.
  async function abrir(contato: CrmContact) {
    if (!contato.opportunity_id) {
      onAviso('Este contato ainda não tem oportunidade aberta.')
      return
    }
    const card = await fetchCard(clientId, contato.opportunity_id)
    if (card) onOpen(card)
    else onAviso('Não foi possível abrir este card.')
  }

  const totalPaginas = Math.max(1, Math.ceil(total / TAMANHO_PAGINA_CONTATOS))
  const de = total === 0 ? 0 : page * TAMANHO_PAGINA_CONTATOS + 1
  const ate = Math.min(total, (page + 1) * TAMANHO_PAGINA_CONTATOS)

  return (
    <>
      <div className="crm-search">
        <input
          type="search"
          placeholder="Buscar por nome ou telefone…"
          value={digitado}
          onChange={(e) => setDigitado(e.target.value)}
        />
      </div>

      {carregando ? (
        <div className="state"><div className="spinner" />Carregando contatos…</div>
      ) : (
        <>
          <div className="table-wrap">
            <table className="data-table">
              <thead>
                <tr>
                  <th>Nome</th>
                  <th>Telefone</th>
                  <th>Etapa</th>
                  <th style={{ textAlign: 'right' }}>Mensagens</th>
                  <th style={{ textAlign: 'right' }}>Última atividade</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                {rows.length === 0 ? (
                  <tr>
                    <td colSpan={6} className="table-empty">
                      {/* "Nenhum contato" quando a consulta falhou seria
                          número errado em silêncio. A falha é dita. */}
                      {falhou
                        ? 'Não foi possível carregar os contatos. Tente de novo.'
                        : busca ? 'Nenhum contato encontrado para essa busca.'
                        // Com filtro ativo, "nenhum contato ainda" mentiria:
                        // existem contatos, só não neste recorte.
                        : temFiltro(filtros) ? 'Nenhum contato neste recorte de filtro.'
                        : 'Nenhum contato ainda.'}
                    </td>
                  </tr>
                ) : rows.map((c) => (
                  <tr key={c.contact_id}>
                    <td>
                      <button className="crm-link" onClick={() => abrir(c)} title="Abrir card">
                        {c.full_name || '—'}
                      </button>
                    </td>
                    <td>{fmtTelefone(c.phone_normalized)}</td>
                    <td>
                      {c.stage_label
                        ? <span className={`crm-badge ${classeEtapa(c.stage_code)}`}>{c.stage_label}</span>
                        : <span className="cell-muted">Sem oportunidade</span>}
                    </td>
                    <td style={{ textAlign: 'right' }}>{c.messages_total.toLocaleString('pt-BR')}</td>
                    <td style={{ textAlign: 'right' }}>
                      <span className="cell-muted">{fmtDataCurta(c.last_activity_at)}</span>
                    </td>
                    <td style={{ textAlign: 'right' }}>
                      {c.whatsapp_url && (
                        <a className="crm-wa-mini" href={c.whatsapp_url} target="_blank" rel="noopener noreferrer">
                          WhatsApp
                        </a>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          <div className="pager">
            <span className="pager-info">
              {total > 0 ? `${de}–${ate} de ${total.toLocaleString('pt-BR')}` : 'Nenhum resultado'}
            </span>
            <div className="pager-btns">
              <button className="sortbtn" disabled={page === 0} onClick={() => setPage((p) => Math.max(0, p - 1))}>
                ← Anterior
              </button>
              <span className="pager-page">Página {page + 1} de {totalPaginas}</span>
              <button className="sortbtn" disabled={page + 1 >= totalPaginas} onClick={() => setPage((p) => p + 1)}>
                Próxima →
              </button>
            </div>
          </div>
        </>
      )}
    </>
  )
}
