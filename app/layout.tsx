import type { Metadata } from 'next'
import './globals.css'

export const metadata: Metadata = {
  title: 'ImpulsHub',
  description: 'Painel de resultados de marketing',
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
