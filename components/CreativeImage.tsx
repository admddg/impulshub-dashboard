'use client'

import { useEffect, useState } from 'react'
import {
  creativeImageSourcesKey,
  creativeImageStatusLabel,
  initialCreativeImageState,
  nextCreativeImageState,
  type CreativeImageState,
} from '@/lib/creative-image'

type CreativeImageProps = {
  sources: Array<string | null | undefined>
  alt: string
  imageClassName: string
  fallbackClassName: string
  sourceIdentity?: string
  onClick?: (src: string) => void
}

/**
 * Image boundary for Meta creative URLs. It never rewrites a signed URL and
 * tries every later usable source after the current source fails.
 */
export default function CreativeImage({
  sources,
  alt,
  imageClassName,
  fallbackClassName,
  sourceIdentity = '',
  onClick,
}: CreativeImageProps) {
  const candidates = sources.filter((source): source is string => Boolean(source?.trim()))
  const sourcesKey = creativeImageSourcesKey(candidates, sourceIdentity)
  const [state, setState] = useState<CreativeImageState & { key: string }>(() => ({
    ...initialCreativeImageState(candidates),
    key: sourcesKey,
  }))

  useEffect(() => {
    if (state.key !== sourcesKey) {
      setState({ ...initialCreativeImageState(candidates), key: sourcesKey })
    }
  }, [candidates, sourcesKey, state.key])

  const activeState = state.key === sourcesKey
    ? state
    : { ...initialCreativeImageState(candidates), key: sourcesKey }
  const src = candidates[activeState.index]
  const status = activeState.status

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
        const next = nextCreativeImageState(candidates, activeState.index)
        setState({ ...next, key: sourcesKey })
      }}
    />
  )
}
