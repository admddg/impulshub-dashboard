import { redirect } from 'next/navigation'

// A /operacao foi substituída pela área /agencia, que consome as RPCs internas
// (get_internal_agency_overview e get_internal_operations_feed) em vez de ler
// as views de saúde direto. O redirect mantém links e favoritos antigos vivos.
export default function OperacaoPage() {
  redirect('/agencia/tracking')
}
