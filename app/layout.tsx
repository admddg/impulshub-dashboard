import type { Metadata } from 'next'
import './globals.css'

export const metadata: Metadata = {
  // O template faz cada página herdar o sufixo: "Visão geral · ImpulsHub".
  title: {
    default: 'ImpulsHub — Painel de informações',
    template: '%s · ImpulsHub',
  },
  description: 'Painel de resultados de marketing, do investimento em mídia à venda no CRM.',
  icons: { icon: '/logo-impuls-bolinha.png', apple: '/logo-impuls-bolinha.png' },
}

export default function RootLayout({
  children,
}: {
  children: React.ReactNode
}) {
  return (
    <html lang="pt-BR">
      <body>{children}</body>
    </html>
  )
}
