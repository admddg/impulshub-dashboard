'use client'

export default function Lightbox({ src, alt, onClose }: { src: string; alt: string; onClose: () => void }) {
  return (
    <div className="lightbox" onClick={onClose}>
      <div className="lightbox-inner" onClick={(e) => e.stopPropagation()}>
        <button className="lightbox-close" onClick={onClose}>×</button>
        <img src={src} alt={alt} />
      </div>
    </div>
  )
}
