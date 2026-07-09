import DashboardClient from '@/components/DashboardClient'

export default function ClientDashboardPage({ params }: { params: { client_slug: string } }) {
  return <DashboardClient clientSlug={params.client_slug} />
}
