'use client'

import { useEffect, useState } from 'react'
import {
  fetchMyRole, fetchOwners, fetchLossReasons, fetchBoardCounts,
  temFiltro, intervaloDoPreset, filtrosPadrao, PRESET_PADRAO, FILTROS_VAZIOS, SEM_PROPRIETARIO,
  type BoardCount, type CrmCard, type CrmFiltros, type CrmOwner, type LossReason,
  type PresetData,
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

const PRESETS: { id: PresetData; label: string }[] = [
  { id: 'todos', label: 'Todos' },
  { id: '7d', label: '7 dias' },
  { id: '30d', label: '30 dias' },
  { id: 'custom', label: 'Personalizado' },
]

// 'YYYY-MM-DD' -> 'DD/MM/AA', por manipulação de string.
//
// De propósito não usa `new Date()`: uma data pura vira meia-noite UTC, e
// `toLocaleDateString` num fuso negativo como o do Brasil devolveria o dia
// anterior. O rótulo mostraria 12/09 para um filtro que começa em 13/09.
function rotuloData(iso: string): string {
  const [y, m, d] = iso.split('-')
  return `${d}/${m}/${y.slice(2)}`
}

// Dias civis cobertos, contando as duas pontas — é assim que o banco conta,
// com `opened_at < (ate + 1)`. Serve para o rótulo dizer em voz alta quantos
// dias o preset pegou, em vez de deixar o nome do botão responder sozinho.
function diasNoIntervalo(de: string, ate: string): number {
  const ms = new Date(ate + 'T00:00:00Z').getTime() - new Date(de + 'T00:00:00Z').getTime()
  return Math.max(0, Math.round(ms / 86400000) + 1)
}

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
  // A aba abre nos últimos 7 dias — ver PRESET_PADRAO em lib/crm.ts.
  const [filtros, setFiltros] = useState<CrmFiltros>(filtrosPadrao)

  // Estado só de interface: qual botão está aceso. A verdade do filtro continua
  // sendo `filtros.de` / `filtros.ate` — o preset apenas os preenche.
  const [preset, setPreset] = useState<PresetData>(PRESET_PADRAO)

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
    // Trocar de cliente volta ao padrão. `filtrosPadrao()` devolve o mesmo
    // objeto enquanto o dia não vira, então isto não dispara recarga extra.
    setFiltros(filtrosPadrao())
    setPreset(PRESET_PADRAO)

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

  // O preset é só atalho de preenchimento: escreve no mesmo `de`/`ate` que os
  // campos manuais escreveriam. Nada abaixo daqui sabe que ele existe.
  function escolhePreset(p: PresetData) {
    setPreset(p)
    // "Personalizado" mantém o intervalo que estava, para a pessoa ajustar a
    // partir dele em vez de começar do zero.
    if (p === 'custom') return
    const { de, ate } = intervaloDoPreset(p)
    // Devolver o mesmo objeto quando nada muda evita uma recarga à toa.
    setFiltros((f) => (f.de === de && f.ate === ate ? f : { ...f, de, ate }))
  }

  function limpaFiltros() {
    setPreset('todos')
    setFiltros(FILTROS_VAZIOS)
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
          <label>Criado em</label>
          <div className="sortbtns">
            {PRESETS.map((p) => (
              <button
                key={p.id}
                className={`sortbtn ${preset === p.id ? 'active' : ''}`}
                onClick={() => escolhePreset(p.id)}
              >
                {p.label}
              </button>
            ))}
          </div>
        </div>

        {/* Os campos manuais só existem em "Personalizado". Nos presets eles
            seriam duas caixas que a pessoa não pode editar sem desfazer o
            preset — ruído. */}
        {preset === 'custom' && (
          <>
            <div className="crm-filter">
              <label htmlFor="crm-de">De</label>
              <input
                id="crm-de"
                type="date"
                value={filtros.de}
                onChange={(e) => mudaFiltro({ de: e.target.value })}
              />
            </div>

            <div className="crm-filter">
              <label htmlFor="crm-ate">Até</label>
              <input
                id="crm-ate"
                type="date"
                value={filtros.ate}
                onChange={(e) => mudaFiltro({ ate: e.target.value })}
              />
            </div>
          </>
        )}

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
          <button className="crm-btn crm-filters-clear" onClick={limpaFiltros}>
            Limpar filtros
          </button>
        )}
      </div>

      {/* O intervalo resolvido, escrito por extenso. Com preset, é o que tira a
          dúvida de quantos dias "7 dias" realmente pegou. */}
      {(filtros.de || filtros.ate) && (
        <div className="crm-filters-range">
          Criados {filtros.de ? `de ${rotuloData(filtros.de)}` : 'até'}
          {filtros.de && filtros.ate ? ' a ' : ' '}
          {filtros.ate ? rotuloData(filtros.ate) : 'em diante'}
          {filtros.de && filtros.ate ? ` · ${diasNoIntervalo(filtros.de, filtros.ate)} dias` : ''}
        </div>
      )}

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
        <ContactsList clientId={clientId} filtros={filtros} onOpen={setAberto} onAviso={setAviso} />
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
