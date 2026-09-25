'use client'

import { useState } from 'react'
import {
  creativeImageStatusLabel,
  diagnoseCreativeUrl,
  type CreativeImageStatus,
} from '@/lib/creative-image'

type CreativeImageProps = {
  sources: Array<string | null | undefined>
  alt: string
  imageClassName: string
  fallbackClassName: string
  onClick?: (src: string) => void
}

/**
 * Image boundary for Meta creative URLs. It never rewrites a signed URL and
 * tries the next source only after the current source fails.
 */
export default function CreativeImage({
  sources,
  alt,
  imageClassName,
  fallbackClassName,
  onClick,
}: CreativeImageProps) {
  const candidates = sources.filter((source): source is string => Boolean(source?.trim()))
  const firstUsable = candidates.findIndex((source) => diagnoseCreativeUrl(source) === 'available')
  const [index, setIndex] = useState(firstUsable >= 0 ? firstUsable : 0)
  const [status, setStatus] = useState<CreativeImageStatus>(() =>
    diagnoseCreativeUrl(candidates[firstUsable >= 0 ? firstUsable : 0]),
  )
  const src = candidates[index]

  if (!src || status !== 'available') {
    const label = creativeImageStatusLabel(status)
    return (
      <div className={fallbackClassName} role="img" aria-label={`${alt}: ${label}`}>
        <span>{label}</span>
      </div>
    )
  }

  return (
    // eslint-disable-next-line @next/next/no-img-element
    <img
      className={imageClassName}
      src={src}
      alt={alt}
      loading="lazy"
      onClick={() => onClick?.(src)}
      onError={() => {
        const next = index + 1
        if (next < candidates.length) {
          setIndex(next)
          setStatus(diagnoseCreativeUrl(candidates[next]))
        } else {
          setStatus('inaccessible')
        }
      }}
    />
  )
}
