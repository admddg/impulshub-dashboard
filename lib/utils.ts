// ---------------------------------------------------------------------------
// Utilidades de data, período e formatação.
// Tudo que é "cálculo puro" mora aqui, separado da tela, pra ficar fácil de ler.
// ---------------------------------------------------------------------------

// Formata uma data como 'YYYY-MM-DD' (formato que o Supabase entende no filtro).
function toISODate(d: Date): string {
  return d.toISOString().slice(0, 10)
}

export type Period = '7d' | '30d' | 'custom'

// Para período custom, o app passa as datas escolhidas.
export type CustomRange = { start: string; end: string }

// Dado um período escolhido, devolve os dois intervalos: o atual e o anterior
// (pra calcular o "vs. período anterior"). O anterior tem exatamente o mesmo
// tamanho do atual, imediatamente antes dele.
export function getRanges(period: Period, custom?: CustomRange) {
  const today = new Date()
  const end = new Date(today)

  let start = new Date(today)

  if (period === 'custom' && custom) {
    start = new Date(custom.start + 'T00:00:00')
    const customEnd = new Date(custom.end + 'T00:00:00')
    const msPerDay = 24 * 60 * 60 * 1000
    const days = Math.round((customEnd.getTime() - start.getTime()) / msPerDay) + 1
    const prevEnd = new Date(start); prevEnd.setDate(start.getDate() - 1)
    const prevStart = new Date(prevEnd); prevStart.setDate(prevEnd.getDate() - (days - 1))
    return {
      current: { start: custom.start, end: custom.end },
      previous: { start: toISODate(prevStart), end: toISODate(prevEnd) },
    }
  }

  if (period === '7d') {
    start.setDate(end.getDate() - 6)
  } else {
    start.setDate(end.getDate() - 29)
  }

  // duração em dias do período atual
  const msPerDay = 24 * 60 * 60 * 1000
  const days = Math.round((end.getTime() - start.getTime()) / msPerDay) + 1

  // período anterior: mesmo tamanho, logo antes do início do atual
  const prevEnd = new Date(start)
  prevEnd.setDate(start.getDate() - 1)
  const prevStart = new Date(prevEnd)
  prevStart.setDate(prevEnd.getDate() - (days - 1))

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
