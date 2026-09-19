'use client'

import { useEffect, useState } from 'react'
import {
  fetchMyRole, fetchOwners, fetchLossReasons, fetchBoardCounts,
  temFiltro, FILTROS_VAZIOS, SEM_PROPRIETARIO,
  type BoardCount, type CrmCard, type CrmFiltros, type CrmOwner, type LossReason,
} from '@/lib/crm'
import KanbanBoard from '@/components/crm/KanbanBoard'
import ContactsList from '@/components/crm/ContactsList'
import CardDrawer from '@/components/crm/CardDrawer'

// A aba CRM. Duas visões da mesma base: o kanban, para trabalhar a fila, e a
// lista, para achar uma pessoa pelo nome ou telefone.
//
// Esta aba não tem seletor de período: kanban é estado atual, não recorte de
// tempo. O filtro "criado em" é outra coisa — recorta por `opened_at` e a
// contagem do topo é recortada junto, pela mesma função do banco.

type Visao = 'kanban' | 'lista'

export default function CrmTab({ clientId }: { clientId: string }) {
  const [carregandoRef, setCarregandoRef] = useState(true)
  const [carregandoBoard, setCarregandoBoard] = useState(true)
  const [visao, setVisao] = useState<Visao>('kanban')
  const [canWrite, setCanWrite] = useState(false)
  const [stages, setStages] = useState<BoardCount[]>([])
  const [owners, setOwners] = useState<CrmOwner[]>([])
  const [lossReasons, setLossReasons] = useState<LossReason[]>([])
  const [aberto, setAberto] = useState<CrmCard | null>(null)
  const [aviso, setAviso] = useState('')
  const [filtros, setFiltros] = useState<CrmFiltros>(FILTROS_VAZIOS)

  // Muda a cada ação de escrita e a cada troca de filtro. As colunas observam
  // e voltam para a primeira página: sem isso, trocar o filtro deixaria a
  // coluna paginando a partir de um offset do recorte anterior.
  const [resetToken, setResetToken] = useState(0)

  // Referências: papel, proprietários e motivos. Não dependem do filtro.
  useEffect(() => {
    let alive = true
    setCarregandoRef(true)
    setAberto(null)
    setAviso('')
    setFiltros(FILTROS_VAZIOS)

    Promise.all([fetchMyRole(clientId), fetchOwners(clientId), fetchLossReasons()])
      .then(([role, owners, reasons]) => {
        if (!alive) return
        setCanWrite(role.can_write)
        setOwners(owners)
        setLossReasons(reasons)
        setCarregandoRef(false)
      })

    return () => { alive = false }
  }, [clientId])

  // Contagens: recarregam quando o cliente ou o filtro mudam. É a única fonte
  // do número no topo de cada coluna.
  useEffect(() => {
    let alive = true
    setCarregandoBoard(true)
    fetchBoardCounts(clientId, filtros).then((counts) => {
      if (!alive) return
      setStages(counts)
      setResetToken((t) => t + 1)
      setCarregandoBoard(false)
    })
    return () => { alive = false }
  }, [clientId, filtros])

  // Uma ação mudou alguma coisa no banco: recarrega as contagens (6 linhas)
  // COM o filtro corrente e manda as colunas se reconstruírem.
  async function aposAcao() {
    const counts = await fetchBoardCounts(clientId, filtros)
    setStages(counts)
    setResetToken((t) => t + 1)
  }

  // O drawer devolve o card que a RPC retornou. Ele vira a verdade na tela, e
  // o board se refaz porque a etapa pode ter mudado.
  function cardAlterado(card: CrmCard) {
    setAberto(card)
    aposAcao()
  }

  function mudaFiltro(troca: Partial<CrmFiltros>) {
    setFiltros((f) => ({ ...f, ...troca }))
  }

  // Só a primeira carga esconde a tela inteira. Recarregar contagem por troca
  // de filtro mantém a barra montada: desmontá-la tiraria o foco do campo que
  // a pessoa acabou de mexer.
  if (carregandoRef) {
    return <div className="state"><div className="spinner" />Carregando CRM…</div>
  }

  const filtrado = temFiltro(filtros)
  const totalCards = stages.reduce((s, e) => s + e.opportunities, 0)
  const intervaloInvertido = !!(filtros.de && filtros.ate && filtros.de > filtros.ate)

  return (
    <>
      <div className="crm-toolbar">
        <div className="sortbtns">
          <button className={`sortbtn ${visao === 'kanban' ? 'active' : ''}`} onClick={() => setVisao('kanban')}>
            Kanban
          </button>
          <button className={`sortbtn ${visao === 'lista' ? 'active' : ''}`} onClick={() => setVisao('lista')}>
            Contatos
          </button>
        </div>
        {!canWrite && (
          <span className="crm-readonly">Somente leitura</span>
        )}
      </div>

      <div className="crm-filters">
        <div className="crm-filter">
          <label htmlFor="crm-de">Criado de</label>
          <input
            id="crm-de"
            type="date"
            value={filtros.de}
            onChange={(e) => mudaFiltro({ de: e.target.value })}
          />
        </div>

        <div className="crm-filter">
          <label htmlFor="crm-ate">até</label>
          <input
            id="crm-ate"
            type="date"
            value={filtros.ate}
            onChange={(e) => mudaFiltro({ ate: e.target.value })}
          />
        </div>

        <div className="crm-filter">
          <label htmlFor="crm-owner">Proprietário</label>
          <select
            id="crm-owner"
            className="select-native"
            value={filtros.owner}
            onChange={(e) => mudaFiltro({ owner: e.target.value })}
          >
            <option value="">Todos</option>
            <option value={SEM_PROPRIETARIO}>Sem proprietário</option>
            {owners.map((o) => (
              <option key={o.profile_id} value={o.profile_id}>
                {o.display_name || 'Sem nome'}
              </option>
            ))}
          </select>
        </div>

        {filtrado && (
          <button className="crm-btn crm-filters-clear" onClick={() => setFiltros(FILTROS_VAZIOS)}>
            Limpar filtros
          </button>
        )}
      </div>

      {intervaloInvertido && (
        <div className="crm-aviso">
          A data inicial é posterior à final, então o recorte é vazio de propósito — não é falha de carregamento.
        </div>
      )}

      {aviso && (
        <div className="crm-aviso">
          {aviso}
          <button onClick={() => setAviso('')} aria-label="Fechar aviso">×</button>
        </div>
      )}

      {/* `v_crm_contacts_v1` não expõe `opened_at` nem `owner_profile_id`, e o
          navegador não alcança o schema `crm` para buscá-los. Em vez de deixar
          o filtro parecer aplicado aqui, a tela diz que não está. */}
      {visao === 'lista' && filtrado && (
        <div className="crm-aviso">
          Os filtros acima valem no Kanban. A lista de contatos ainda mostra todos —
          a view de contatos não expõe data de criação nem proprietário.
        </div>
      )}

      {visao === 'kanban' ? (
        // O board só monta com a contagem do filtro corrente em mãos. Enquanto
        // ela não chega, mostrar as colunas seria exibir o cabeçalho do recorte
        // anterior sobre cards do novo — header dizendo 164 com 12 na tela.
        carregandoBoard ? (
          <div className="state"><div className="spinner" />Carregando…</div>
        ) : stages.length === 0 ? (
          // Pode ser cliente fora do CRM ou falha na consulta. A tela não
          // escolhe uma causa que não sabe — o detalhe está no console.
          <div className="state">
            Não há pipeline de CRM para este cliente, ou não foi possível carregá-lo.
          </div>
        ) : (
          <KanbanBoard
            clientId={clientId}
            stages={stages}
            canWrite={canWrite}
            resetToken={resetToken}
            filtros={filtros}
            onOpen={setAberto}
            onActed={aposAcao}
            onAviso={setAviso}
          />
        )
      ) : (
        <ContactsList clientId={clientId} onOpen={setAberto} onAviso={setAviso} />
      )}

      {aberto && (
        <CardDrawer
          card={aberto}
          stages={stages}
          owners={owners}
          lossReasons={lossReasons}
          canWrite={canWrite}
          onClose={() => setAberto(null)}
          onChanged={cardAlterado}
          onAviso={setAviso}
        />
      )}

      {stages.length > 0 && !carregandoBoard && (
        <div className="muted-note">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><circle cx="12" cy="12" r="10" /><path d="M12 16v-4M12 8h.01" /></svg>
          {totalCards.toLocaleString('pt-BR')} {filtrado ? 'oportunidades no recorte atual' : 'oportunidades'}.
          Etapa, contagem e histórico vêm prontos do banco — o painel não recalcula nenhum deles.
        </div>
      )}
    </>
  )
}
