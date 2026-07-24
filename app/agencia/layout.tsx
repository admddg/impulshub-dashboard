import type { Metadata } from 'next'
import AgencyShell from '@/components/AgencyShell'

export const metadata: Metadata = { title: 'Agência' }

export default function AgenciaLayout({ children }: { children: React.ReactNode }) {
  return <AgencyShell>{children}</AgencyShell>
}
