'use client'

import { useState } from 'react'

export type Column<T> = {
  key: string
  header: string
  render: (row: T) => React.ReactNode
  sortValue?: (row: T) => number | string   // valor pra ordenação (default: não ordenável)
  align?: 'left' | 'right'
  width?: number | string
}

export default function DataTable<T>({ columns, rows, initialSort, totalRow }: {
  columns: Column<T>[]
  rows: T[]
  initialSort?: { key: string; dir: 'asc' | 'desc' }
  totalRow?: Partial<Record<string, React.ReactNode>>   // conteúdo por key de coluna para a linha de soma
}) {
  const [sort, setSort] = useState(initialSort ?? null)

  let sorted = rows
  if (sort) {
    const col = columns.find((c) => c.key === sort.key)
    if (col?.sortValue) {
      sorted = [...rows].sort((a, b) => {
        const va = col.sortValue!(a)
        const vb = col.sortValue!(b)
        if (va < vb) return sort.dir === 'asc' ? -1 : 1
        if (va > vb) return sort.dir === 'asc' ? 1 : -1
        return 0
      })
    }
  }

  function toggleSort(key: string) {
    const col = columns.find((c) => c.key === key)
    if (!col?.sortValue) return
    setSort((s) =>
      s?.key === key
        ? { key, dir: s.dir === 'asc' ? 'desc' : 'asc' }
        : { key, dir: 'desc' }
    )
  }

  return (
    <div className="table-wrap">
      <table className="data-table">
        <thead>
          <tr>
            {columns.map((c) => (
              <th key={c.key}
                onClick={() => toggleSort(c.key)}
                style={{
                  textAlign: c.align ?? 'left',
                  cursor: c.sortValue ? 'pointer' : 'default',
                  width: c.width,
                }}>
                {c.header}
                {sort?.key === c.key && (
                  <span className="sort-arrow">{sort.dir === 'asc' ? ' ↑' : ' ↓'}</span>
                )}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {sorted.length === 0 ? (
            <tr><td colSpan={columns.length} className="table-empty">Nenhum dado no período selecionado.</td></tr>
          ) : (
            sorted.map((row, i) => (
              <tr key={i}>
                {columns.map((c) => (
                  <td key={c.key} style={{ textAlign: c.align ?? 'left' }}>{c.render(row)}</td>
                ))}
              </tr>
            ))
          )}
        </tbody>
        {totalRow && sorted.length > 0 && (
          <tfoot>
            <tr className="table-total">
              {columns.map((c) => (
                <td key={c.key} style={{ textAlign: c.align ?? 'left' }}>{totalRow[c.key] ?? ''}</td>
              ))}
            </tr>
          </tfoot>
        )}
      </table>
    </div>
  )
}
