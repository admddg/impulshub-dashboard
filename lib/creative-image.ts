export type CreativeImageStatus = 'missing' | 'expired' | 'available' | 'inaccessible'

const META_CDN_HOSTS = ['fbcdn.net', 'facebook.com', 'fbsbx.com']

function isMetaCdnUrl(url: string): boolean {
  try {
    const host = new URL(url).hostname.toLowerCase()
    return META_CDN_HOSTS.some((suffix) => host === suffix || host.endsWith(`.${suffix}`))
  } catch {
    return false
  }
}

/**
 * Diagnoses only what can be known without changing or refreshing a signed URL.
 * A browser load error deliberately remains `inaccessible` because CORS and
 * network failures do not expose the HTTP status to an <img> element.
 */
export function diagnoseCreativeUrl(
  url: string | null | undefined,
  nowSeconds: number = Math.floor(Date.now() / 1000),
): CreativeImageStatus {
  if (!url || !url.trim()) return 'missing'

  try {
    const parsed = new URL(url)
    if (isMetaCdnUrl(url)) {
      const expiresAt = parsed.searchParams.get('oe')
      if (expiresAt && /^[0-9a-f]+$/i.test(expiresAt)) {
        const expires = Number.parseInt(expiresAt, 16)
        if (Number.isFinite(expires) && expires <= nowSeconds) return 'expired'
      }
    }
    return 'available'
  } catch {
    return 'inaccessible'
  }
}

export function creativeImageStatusLabel(status: CreativeImageStatus): string {
  switch (status) {
    case 'missing': return 'URL ausente'
    case 'expired': return 'URL expirada'
    case 'inaccessible': return 'URL expirada/inacessível'
    case 'available': return ''
  }
}
