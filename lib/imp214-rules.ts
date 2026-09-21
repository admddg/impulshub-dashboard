export type OwnerRole = 'crc' | 'sales'
export type OrigemFiltro = '' | 'anuncio' | 'organico'

export type CardOrigem = {
  conversion_source: string | null
  ctwa_clid: string | null
  meta_ad_id: string | null
}

export function origemDoCard(card: CardOrigem): 'anuncio' | 'organico' {
  return card.conversion_source || card.ctwa_clid || card.meta_ad_id ? 'anuncio' : 'organico'
}

export type FiltrosAtivos = {
  de: string
  ate: string
  ownerRole: OwnerRole | ''
  owner: string
  origem: OrigemFiltro
}

export function temFiltro(f: FiltrosAtivos): boolean {
  return !!(f.de || f.ate || f.ownerRole || f.owner || f.origem)
}
