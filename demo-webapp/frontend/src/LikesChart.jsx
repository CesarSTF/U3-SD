import { useMemo, useState } from 'react'

const SERIES_VARS = ['--chart-series-1', '--chart-series-2', '--chart-series-3']
const WIDTH = 400
const HEIGHT = 150
const PAD_LEFT = 30
const PAD_RIGHT = 12
const PAD_TOP = 12
const PAD_BOTTOM = 14

function niceMax(value) {
  if (value <= 0) return 4
  const magnitude = Math.pow(10, Math.floor(Math.log10(value)))
  const normalized = value / magnitude
  let step
  if (normalized <= 1) step = 1
  else if (normalized <= 2) step = 2
  else if (normalized <= 5) step = 5
  else step = 10
  return step * magnitude
}

function LikesChart({ posts, history }) {
  const [hoverIndex, setHoverIndex] = useState(null)

  const series = posts.map((post, i) => ({
    id: post.id,
    name: post.autor,
    colorVar: SERIES_VARS[i % SERIES_VARS.length],
    points: history[post.id] || [],
  }))

  const sampleCount = series.reduce((max, s) => Math.max(max, s.points.length), 0)

  const maxCount = useMemo(() => {
    let m = 0
    series.forEach(s => s.points.forEach(p => { if (p.count > m) m = p.count }))
    return niceMax(m)
  }, [series])

  if (sampleCount < 2) {
    return <p className="loading-text">Recolectando actividad de likes...</p>
  }

  const plotW = WIDTH - PAD_LEFT - PAD_RIGHT
  const plotH = HEIGHT - PAD_TOP - PAD_BOTTOM
  const stepX = sampleCount > 1 ? plotW / (sampleCount - 1) : 0

  const xAt = (i) => PAD_LEFT + i * stepX
  const yAt = (count) => PAD_TOP + plotH - (count / maxCount) * plotH

  const linePath = (points) => {
    const offset = sampleCount - points.length
    return points
      .map((p, idx) => `${idx === 0 ? 'M' : 'L'} ${xAt(offset + idx).toFixed(1)} ${yAt(p.count).toFixed(1)}`)
      .join(' ')
  }

  const handleMove = (e) => {
    const rect = e.currentTarget.getBoundingClientRect()
    const ratio = Math.min(1, Math.max(0, (e.clientX - rect.left) / rect.width))
    setHoverIndex(Math.round(ratio * (sampleCount - 1)))
  }

  const valueAt = (s, idx) => {
    const offset = sampleCount - s.points.length
    const localIdx = idx - offset
    return localIdx >= 0 && localIdx < s.points.length ? s.points[localIdx].count : null
  }

  return (
    <div className="chart-wrap">
      <svg
        viewBox={`0 0 ${WIDTH} ${HEIGHT}`}
        className="chart-svg"
        preserveAspectRatio="none"
        role="img"
        aria-label="Historial de likes por post"
      >
        {[0, 0.5, 1].map(f => {
          const y = PAD_TOP + plotH - f * plotH
          return (
            <g key={f}>
              <line x1={PAD_LEFT} x2={WIDTH - PAD_RIGHT} y1={y} y2={y} className="chart-gridline" />
              <text x={PAD_LEFT - 6} y={y + 3} textAnchor="end" className="chart-axis-label">
                {Math.round(maxCount * f)}
              </text>
            </g>
          )
        })}

        {hoverIndex !== null && (
          <line
            x1={xAt(hoverIndex)}
            x2={xAt(hoverIndex)}
            y1={PAD_TOP}
            y2={PAD_TOP + plotH}
            className="chart-crosshair"
          />
        )}

        {series.map(s => {
          const last = s.points[s.points.length - 1]
          return (
            <g key={s.id}>
              {s.points.length >= 2 && (
                <path
                  d={linePath(s.points)}
                  fill="none"
                  stroke={`var(${s.colorVar})`}
                  strokeWidth="2"
                  strokeLinecap="round"
                  strokeLinejoin="round"
                />
              )}
              {last && (
                <circle
                  cx={xAt(sampleCount - 1)}
                  cy={yAt(last.count)}
                  r="4"
                  fill={`var(${s.colorVar})`}
                  stroke="var(--chart-surface)"
                  strokeWidth="2"
                />
              )}
            </g>
          )
        })}

        <rect
          x={PAD_LEFT}
          y={PAD_TOP}
          width={plotW}
          height={plotH}
          fill="transparent"
          onMouseMove={handleMove}
          onMouseLeave={() => setHoverIndex(null)}
        />
      </svg>

      {hoverIndex !== null && (
        <div
          className="chart-tooltip"
          style={{ left: `${(xAt(hoverIndex) / WIDTH) * 100}%` }}
        >
          {series.map(s => {
            const val = valueAt(s, hoverIndex)
            return (
              <div className="chart-tooltip-row" key={s.id}>
                <span className="chart-tooltip-key" style={{ background: `var(${s.colorVar})` }}></span>
                <span className="chart-tooltip-value">{val !== null ? val : '—'}</span>
                <span className="chart-tooltip-name">{s.name}</span>
              </div>
            )
          })}
        </div>
      )}

      <div className="chart-legend">
        {series.map(s => {
          const last = s.points[s.points.length - 1]
          return (
            <div className="chart-legend-item" key={s.id}>
              <span className="chart-legend-dot" style={{ background: `var(${s.colorVar})` }}></span>
              <span className="chart-legend-name">{s.name}</span>
              <span className="chart-legend-value">{last ? last.count : '—'}</span>
            </div>
          )
        })}
      </div>
    </div>
  )
}

export default LikesChart
