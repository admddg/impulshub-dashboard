// ---------------------------------------------------------------------------
// Utilidades de data, período e formatação.
// Tudo que é "cálculo puro" mora aqui, separado da tela, pra ficar fácil de ler.
// ---------------------------------------------------------------------------

// Formata uma data como 'YYYY-MM-DD'. Recebe sempre datas construídas em UTC
// meia-noite (ver diaDeHojeSP), então o slice é seguro.
function toISODate(d: Date): string {
  return d.toISOString().slice(0, 10)
}

// O servidor roda em UTC, mas o negócio é America/Sao_Paulo. Usar new Date()
// direto faz o dia virar às 21h no horário de Brasília. Aqui resolvemos o dia
// civil correto no fuso do cliente e devolvemos como UTC meia-noite, para que
// toda a aritmética de dias abaixo fique livre de fuso.
function diaDeHojeSP(): Date {
  const partes = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'America/Sao_Paulo',
    year: 'numeric', month: '2-digit', day: '2-digit',
  }).format(new Date())
  const [y, m, d] = partes.split('-').map(Number)
  return new Date(Date.UTC(y, m - 1, d))
}

// D-1: o dashboard inteiro fecha em ontem.
//
// Motivo: o sync de mídia roda de madrugada e grava até D-1. Não existe linha
// de investimento do dia corrente em nenhuma fonte. Os leads do CRM, ao
// contrário, entram ao vivo pelo webhook. Incluir hoje significa dividir um
// investimento que falta um dia por um número de leads completo — o CPL sai
// artificialmente baixo e o ROAS artificialmente alto, e a distorção piora
// conforme o dia avança.
export function dataDeCorte(): Date {
  const d = diaDeHojeSP()
  d.setUTCDate(d.getUTCDate() - 1)
  return d
}

// 'YYYY-MM-DD' do último dia com dado fechado. Usado para travar o seletor.
export function dataDeCorteISO(): string {
  return toISODate(dataDeCorte())
}

// 'DD/MM' para o rótulo "Dados até" ao lado do seletor de período.
export function dataDeCorteLabel(): string {
  const iso = dataDeCorteISO()
  const [, m, d] = iso.split('-')
  return `${d}/${m}`
}

export type Period = '7d' | '15d' | '30d' | '90d' | 'custom'

// Para período custom, o app passa as datas escolhidas.
export type CustomRange = { start: string; end: string }

// Períodos curtos não permitem leitura de maturação de funil (a coorte ainda
// não teve tempo de avançar). O seletor mostra aviso quando um destes está ativo.
export const PERIODOS_CURTOS: Period[] = ['7d']

// Dado um período escolhido, devolve os dois intervalos: o atual e o anterior
// (pra calcular o "vs. período anterior"). O anterior tem exatamente o mesmo
// tamanho do atual, imediatamente antes dele. Ambos terminam, no máximo, em D-1.
export function getRanges(period: Period, custom?: CustomRange) {
  const corte = dataDeCorte()
  const msPerDay = 24 * 60 * 60 * 1000

  if (period === 'custom' && custom) {
    // Trava defensiva: mesmo que uma data futura chegue aqui, o fim nunca passa
    // do corte. O input do seletor já bloqueia, isto é a segunda camada.
    const fimEscolhido = custom.end > toISODate(corte) ? toISODate(corte) : custom.end
    const start = new Date(custom.start + 'T00:00:00Z')
    const end = new Date(fimEscolhido + 'T00:00:00Z')
    const days = Math.round((end.getTime() - start.getTime()) / msPerDay) + 1
    const prevEnd = new Date(start); prevEnd.setUTCDate(start.getUTCDate() - 1)
    const prevStart = new Date(prevEnd); prevStart.setUTCDate(prevEnd.getUTCDate() - (days - 1))
    return {
      current: { start: custom.start, end: fimEscolhido },
      previous: { start: toISODate(prevStart), end: toISODate(prevEnd) },
    }
  }

  // 7 | 15 | 30 | 90 dias — sempre terminando em D-1, nunca em hoje
  const daysByPeriod: Record<'7d' | '15d' | '30d' | '90d', number> =
    { '7d': 7, '15d': 15, '30d': 30, '90d': 90 }
  const totalDays = daysByPeriod[period as '7d' | '15d' | '30d' | '90d'] ?? 30

  const end = new Date(corte)
  const start = new Date(corte)
  start.setUTCDate(end.getUTCDate() - (totalDays - 1))

  const prevEnd = new Date(start)
  prevEnd.setUTCDate(start.getUTCDate() - 1)
  const prevStart = new Date(prevEnd)
  prevStart.setUTCDate(prevEnd.getUTCDate() - (totalDays - 1))

  return {
    current: { start: toISODate(start), end: toISODate(end) },
    previous: { start: toISODate(prevStart), end: toISODate(prevEnd) },
  }
}

// Converte um valor que pode vir como string (o Supabase manda numeric como texto),
// null ou undefined, sempre para número. Vazio vira 0.
export function num(v: string | number | null | undefined): number {
  if (v === null || v === undefined || v === '') return 0
  const n = typeof v === 'number' ? v : parseFloat(v)
  return isNaN(n) ? 0 : n
}

// Formata dinheiro em Real brasileiro: 2418.09 -> "2.418"
export function brl(v: number, decimals = 0): string {
  return v.toLocaleString('pt-BR', {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  })
}

// Formata número inteiro simples: 15823 -> "15.823"
export function int(v: number): string {
  return Math.round(v).toLocaleString('pt-BR')
}

// Calcula a variação percentual entre atual e anterior.
// Retorna null quando não dá pra comparar (período anterior era zero).
export function deltaPct(current: number, previous: number): number | null {
  if (previous === 0) return null
  return ((current - previous) / previous) * 100
}

// Formata percentual: 0.234 -> "23,4%". Recebe a razão (0-1) ou já a taxa.
export function pct(v: number, decimals = 1): string {
  return v.toLocaleString('pt-BR', {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  }) + '%'
}

// Consolida qualquer canal cru em: Meta Ads, Google Ads, ou Orgânico.
// O que não for Meta nem Google é tratado como Orgânico.
export function channelBucket(raw: string | null): string {
  if (!raw) return 'Orgânico'
  const s = raw.toLowerCase().trim()
  if (s.includes('meta') || s.includes('facebook') || s.includes('instagram ads')) return 'Meta Ads'
  if (s.includes('google ads') || s === 'google') return 'Google Ads'
  return 'Orgânico'
}

const BUCKET_COLOR: Record<string, string> = {
  'Meta Ads':   '#00313d',
  'Google Ads': '#5fae95',
  'Orgânico':   '#94d2bd',
}

export function channelLabel(raw: string | null): string {
  return channelBucket(raw)
}

export function channelColor(raw: string | null): string {
  return BUCKET_COLOR[channelBucket(raw)] ?? '#94d2bd'
}

// Ordem fixa dos canais no dashboard
export const CHANNEL_ORDER = ['Meta Ads', 'Google Ads', 'Orgânico']

// ---- ENTRADA (lead_entrada): por ONDE o lead chegou ----
// WhatsApp, Formulário (FB), Site. Diferente de origem (canal pago).
export function entradaBucket(raw: string | null): string {
  if (!raw) return 'Outros'
  const s = raw.toLowerCase().trim()
  if (s.includes('whatsapp')) return 'WhatsApp'
  if (s.includes('form_fbads') || s.includes('fbads') || s.includes('formulário') || s.includes('formulario')) return 'Formulário'
  if (s.includes('site')) return 'Site'
  return 'Outros'
}

const ENTRADA_COLOR: Record<string, string> = {
  'WhatsApp':   '#25a35a',
  'Formulário': '#00313d',
  'Site':       '#5fae95',
  'Outros':     '#94d2bd',
}

export function entradaColor(raw: string | null): string {
  return ENTRADA_COLOR[entradaBucket(raw)] ?? '#94d2bd'
}

export const ENTRADA_ORDER = ['WhatsApp', 'Formulário', 'Site', 'Outros']

// As URLs do fbcdn são assinadas (o parâmetro "oh" é um hash que cobre o "stp").
// Mexer no tamanho (remover p64x64) quebra a assinatura e a imagem não carrega.
// Então devolvemos a URL intacta — a melhoria de resolução de vídeo vem do sync
// (trazer um thumbnail maior da API do Meta), não do dashboard.
export function hiResImg(url: string | null | undefined): string | null {
  if (!url) return null
  return url
}
