export type PapelCliente = 'agency' | 'owner' | 'admin' | 'manager' | 'attendant' | 'viewer'

const PAPEIS_DE_GESTAO = new Set<PapelCliente>([
  'owner',
  'admin',
  'manager',
])

const PAPEIS_COM_ACESSO_TOTAL = new Set<PapelCliente>(['agency'])

const ABAS_DO_ATENDENTE = new Set(['crm', 'funnel', 'channels'])

export function tabsVisiveisParaPapel<T extends string>(
  papel: string | null,
  tabs: readonly T[],
): T[] {
  if (papel && PAPEIS_COM_ACESSO_TOTAL.has(papel as PapelCliente)) {
    return [...tabs]
  }

  if (papel && PAPEIS_DE_GESTAO.has(papel as PapelCliente)) {
    return [...tabs]
  }

  if (papel === 'attendant') {
    return tabs.filter((tab) => ABAS_DO_ATENDENTE.has(tab))
  }

  if (papel === 'viewer') {
    return tabs.filter((tab) => tab !== 'crm')
  }

  return []
}
