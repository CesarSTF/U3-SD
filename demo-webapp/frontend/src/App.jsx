import { useState, useEffect, useCallback, useRef } from 'react'
import './App.css'
import LikesChart from './LikesChart.jsx'

const API_URL = import.meta.env.VITE_API_URL || 'http://localhost:3001'
const POLL_INTERVAL = 2000
const ROUTE_ANIM_MS = 700
const NODE_ANIM_MS = 900
const SIMULATE_DOWN_MS = 8000
const MAX_HISTORY = 60

function getInitialTheme() {
  if (typeof window === 'undefined') return 'light'
  const stored = window.localStorage.getItem('theme')
  if (stored === 'light' || stored === 'dark') return stored
  return window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'
}

function App() {
  const [posts, setPosts] = useState([])
  const [likeCounts, setLikeCounts] = useState({})
  const [likeHistory, setLikeHistory] = useState({})
  const [clusterStatus, setClusterStatus] = useState(null)
  const [toasts, setToasts] = useState([])
  const [animatingHearts, setAnimatingHearts] = useState({})
  const [lastServedBy, setLastServedBy] = useState({})
  const [theme, setTheme] = useState(getInitialTheme)

  // --- Balanceador de carga (visualización round robin del lado cliente) ---
  const [lbCounts, setLbCounts] = useState({})
  const [route, setRoute] = useState(null) // { nodeId, key }
  const rrIndexRef = useRef(0)

  // --- Circuit breaker: latencia de sondeo, animaciones, caídas y simulación local ---
  const [pollLatency, setPollLatency] = useState(null)
  const [nodeAnim, setNodeAnim] = useState({})
  const [downCounts, setDownCounts] = useState({})
  const [simulatedDown, setSimulatedDown] = useState({})
  const prevEffectiveRef = useRef({})
  const nodeAnimTimersRef = useRef({})

  // --- Tema claro/oscuro ---
  useEffect(() => {
    document.documentElement.setAttribute('data-theme', theme)
  }, [theme])

  const toggleTheme = () => {
    setTheme(prev => {
      const next = prev === 'dark' ? 'light' : 'dark'
      window.localStorage.setItem('theme', next)
      return next
    })
  }

  // --- Fetch posts ---
  useEffect(() => {
    fetch(`${API_URL}/posts`)
      .then(r => r.json())
      .then(setPosts)
      .catch(err => console.error('Error fetching posts:', err))
  }, [])

  // --- Poll like counts (y muestreo para el historial del gráfico) ---
  const fetchLikeCounts = useCallback(() => {
    Promise.all(
      posts.map(post =>
        fetch(`${API_URL}/posts/${post.id}/likes`)
          .then(r => r.json())
          .then(data => ({ id: post.id, count: data.count }))
          .catch(() => ({ id: post.id, count: undefined }))
      )
    ).then(results => {
      const t = Date.now()
      setLikeCounts(prev => {
        const next = { ...prev }
        results.forEach(({ id, count }) => {
          if (count !== undefined) next[id] = count
        })
        return next
      })
      setLikeHistory(prev => {
        const next = { ...prev }
        results.forEach(({ id, count }) => {
          if (count === undefined) return
          const arr = next[id] ? [...next[id]] : []
          arr.push({ t, count })
          next[id] = arr.slice(-MAX_HISTORY)
        })
        return next
      })
    })
  }, [posts])

  useEffect(() => {
    if (posts.length === 0) return
    fetchLikeCounts()
    const interval = setInterval(fetchLikeCounts, POLL_INTERVAL)
    return () => clearInterval(interval)
  }, [posts, fetchLikeCounts])

  // --- Poll cluster status (mide latencia real del sondeo) ---
  useEffect(() => {
    const fetchStatus = () => {
      const start = performance.now()
      fetch(`${API_URL}/status`)
        .then(r => r.json())
        .then(data => {
          setPollLatency(Math.round(performance.now() - start))
          setClusterStatus(data)
        })
        .catch(() => {})
    }
    fetchStatus()
    const interval = setInterval(fetchStatus, POLL_INTERVAL)
    return () => clearInterval(interval)
  }, [])

  // --- Limpia la animación de ruteo del balanceador tras completarse ---
  useEffect(() => {
    if (!route) return
    const timeout = setTimeout(() => setRoute(null), ROUTE_ANIM_MS)
    return () => clearTimeout(timeout)
  }, [route])

  // --- Detecta transiciones de estado (reales o simuladas) para toasts + animación + contador de caídas ---
  useEffect(() => {
    const nodes = clusterStatus?.nodes || []
    if (nodes.length === 0) return

    nodes.forEach(node => {
      const simulated = !!simulatedDown[node.id]
      const effective = simulated ? 'OPEN' : node.circuit
      const prev = prevEffectiveRef.current[node.id]

      if (prev !== undefined && prev !== effective) {
        const tag = simulated ? ' (simulado)' : ''
        if (effective === 'OPEN') {
          addToast(`⚠️ ${node.id} cayó${tag}`, 'error')
          setDownCounts(p => ({ ...p, [node.id]: (p[node.id] || 0) + 1 }))
          triggerNodeAnim(node.id, 'down')
        } else if (effective === 'CLOSED') {
          addToast(`✅ ${node.id} se recuperó${tag}`, 'success')
          triggerNodeAnim(node.id, 'up')
        } else if (effective === 'HALF_OPEN') {
          addToast(`🔄 ${node.id} verificando reconexión`, 'info')
          triggerNodeAnim(node.id, 'checking')
        }
      }
      prevEffectiveRef.current[node.id] = effective
    })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [clusterStatus, simulatedDown])

  const triggerNodeAnim = (nodeId, cls) => {
    setNodeAnim(prev => ({ ...prev, [nodeId]: cls }))
    clearTimeout(nodeAnimTimersRef.current[nodeId])
    nodeAnimTimersRef.current[nodeId] = setTimeout(() => {
      setNodeAnim(prev => {
        const next = { ...prev }
        delete next[nodeId]
        return next
      })
    }, NODE_ANIM_MS)
  }

  // --- Toast system ---
  const addToast = (message, type = 'success') => {
    const id = Date.now() + Math.random()
    setToasts(prev => [...prev, { id, message, type }])
    setTimeout(() => {
      setToasts(prev => prev.filter(t => t.id !== id))
    }, 3000)
  }

  // --- Simular caída de un nodo (solo visual, en el frontend) ---
  const handleSimulateDown = (nodeId) => {
    if (simulatedDown[nodeId]) return
    setSimulatedDown(prev => ({ ...prev, [nodeId]: true }))
    setTimeout(() => {
      setSimulatedDown(prev => {
        const next = { ...prev }
        delete next[nodeId]
        return next
      })
    }, SIMULATE_DOWN_MS)
  }

  // --- Circuito efectivo (real, salvo que esté simulado como caído) ---
  const getEffectiveCircuit = (node) => (simulatedDown[node.id] ? 'OPEN' : node.circuit)

  // --- Elige el siguiente nodo elegible por round robin (mismo criterio que el balanceador real: omite nodos con el circuito abierto) ---
  const pickNextNode = () => {
    const nodes = clusterStatus?.nodes || []
    const eligible = nodes.filter(n => getEffectiveCircuit(n) === 'CLOSED')
    if (eligible.length === 0) return null
    const idx = rrIndexRef.current % eligible.length
    rrIndexRef.current += 1
    return eligible[idx]
  }

  // --- Like handler ---
  const handleLike = async (postId) => {
    // Trigger heart animation
    setAnimatingHearts(prev => ({ ...prev, [postId]: true }))
    setTimeout(() => setAnimatingHearts(prev => ({ ...prev, [postId]: false })), 400)

    // Visualiza a qué nodo enruta el balanceador antes de disparar la petición
    const target = pickNextNode()
    if (target) {
      setRoute({ nodeId: target.id, key: Date.now() })
      setLbCounts(prev => ({ ...prev, [target.id]: (prev[target.id] || 0) + 1 }))
      setLastServedBy(prev => ({ ...prev, [postId]: target.id }))
    } else {
      addToast('Balanceador sin nodos disponibles (todos con el circuito abierto)', 'error')
    }

    try {
      const resp = await fetch(`${API_URL}/posts/${postId}/like`, { method: 'POST' })
      const data = await resp.json()
      if (data.ok) {
        addToast(`Like registrado (seq=${data.seq})`, 'success')
        // Re-fetch this post's count immediately
        const countResp = await fetch(`${API_URL}/posts/${postId}/likes`)
        const countData = await countResp.json()
        if (countData.count !== undefined) {
          setLikeCounts(prev => ({ ...prev, [postId]: countData.count }))
          setLikeHistory(prev => {
            const arr = prev[postId] ? [...prev[postId]] : []
            arr.push({ t: Date.now(), count: countData.count })
            return { ...prev, [postId]: arr.slice(-MAX_HISTORY) }
          })
        }
      } else {
        addToast(data.error || 'Error al dar like', 'error')
      }
    } catch (err) {
      addToast(`Error: ${err.message}`, 'error')
    }
  }

  // --- Helpers ---
  const getCircuitClass = (circuit) => {
    if (!circuit) return ''
    return circuit.toLowerCase()
  }

  const getLbRowClass = (circuit) => {
    if (circuit === 'CLOSED') return 'eligible'
    if (circuit === 'HALF_OPEN') return 'probing'
    return 'excluded'
  }

  const getLbTagLabel = (circuit) => {
    if (circuit === 'CLOSED') return 'Elegible'
    if (circuit === 'HALF_OPEN') return 'Probando'
    return 'Excluido'
  }

  const nodes = clusterStatus?.nodes || []
  const eligibleCount = nodes.filter(n => getEffectiveCircuit(n) === 'CLOSED').length

  return (
    <div className="app-container">
      {/* Header */}
      <header className="app-header">
        <button
          className="theme-toggle"
          onClick={toggleTheme}
          title="Cambiar tema claro/oscuro"
          aria-label="Cambiar tema claro/oscuro"
        >
          {theme === 'dark' ? '☀️' : '🌙'}
        </button>
        <h1 className="app-title">LikeCluster</h1>
        <p className="app-subtitle">Sistema de replicas leaderless con cuorum — Demo en vivo</p>
      </header>

      {/* Gráfico de actividad de likes */}
      <div className="panel chart-panel" id="likes-chart-panel">
        <div className="panel-header">
          <span className="panel-icon lb">📈</span>
          <div>
            <div className="panel-heading">Actividad de Likes</div>
            <p className="panel-caption">Historial en vivo por post (ventana móvil, sondeo cada 2s)</p>
          </div>
        </div>
        <LikesChart posts={posts} history={likeHistory} />
      </div>

      {/* Main layout */}
      <div className="main-layout">
        {/* Feed de posts */}
        <section>
          <div className="section-title">Feed de Posts</div>
          {posts.map(post => (
            <article key={post.id} className="post-card" id={`post-${post.id}`}>
              <div className="post-author">
                <div className="post-avatar">
                  {post.autor.charAt(0).toUpperCase()}
                </div>
                <div>
                  <div className="post-author-name">{post.autor}</div>
                  <div className="post-author-handle">@{post.autor.toLowerCase()}</div>
                </div>
              </div>
              <p className="post-text">{post.texto}</p>
              <div className="post-actions">
                <button
                  className="like-btn"
                  onClick={() => handleLike(post.id)}
                  id={`like-btn-${post.id}`}
                >
                  <span className={`heart-icon ${animatingHearts[post.id] ? 'heart-animate' : ''}`}>
                    ❤
                  </span>
                  Like
                </button>
                <span className="like-count">
                  {likeCounts[post.id] !== undefined ? likeCounts[post.id] : '—'} likes
                </span>
                {lastServedBy[post.id] && (
                  <span
                    className="served-by-badge"
                    title="Simulación de enrutamiento calculada en el frontend (el backend no expone qué nodo atiende cada request)"
                  >
                    atendido por {lastServedBy[post.id]}
                  </span>
                )}
              </div>
            </article>
          ))}
        </section>

        {/* Paneles de arquitectura: Balanceador de Carga + Circuit Breaker */}
        <aside className="side-panels" id="cluster-panel">
          {/* --- Balanceador de Carga --- */}
          <div className="panel" id="lb-panel">
            <div className="panel-header">
              <span className="panel-icon lb">⇄</span>
              <div>
                <div className="panel-heading">Balanceador de Carga</div>
                <p className="panel-caption">
                  Round robin sobre nodos activos · {eligibleCount}/{nodes.length} elegibles ahora
                </p>
              </div>
            </div>

            {nodes.length > 0 ? (
              <div className="lb-diagram">
                <div className="lb-hub">
                  <span className="lb-hub-icon">🌐</span>
                  <span className="lb-hub-label">Cliente → LB</span>
                </div>
                <div className="lb-rows">
                  {nodes.map(node => {
                    const effective = getEffectiveCircuit(node)
                    return (
                      <div
                        key={node.id}
                        className={`lb-row ${getLbRowClass(effective)} ${route?.nodeId === node.id ? 'routing' : ''}`}
                      >
                        <div className="lb-track">
                          {route?.nodeId === node.id && <span className="lb-dot" key={route.key}></span>}
                        </div>
                        <div className="lb-node">
                          <div className="lb-node-info">
                            <span className="lb-node-name">{node.id}</span>
                            <span className={`lb-node-tag ${getLbRowClass(effective)}`}>
                              {getLbTagLabel(effective)}
                            </span>
                          </div>
                          <span className="lb-node-count">
                            <strong>{lbCounts[node.id] || 0}</strong> req. enviadas
                          </span>
                        </div>
                      </div>
                    )
                  })}
                </div>
                {eligibleCount === 0 && (
                  <div className="lb-empty-warning">
                    Ningún nodo elegible: el balanceador no puede enrutar hasta que el circuit breaker cierre al menos uno.
                  </div>
                )}
              </div>
            ) : (
              <p className="loading-text">Conectando al coordinador...</p>
            )}
          </div>

          {/* --- Circuit Breaker --- */}
          <div className="panel" id="cb-panel">
            <div className="panel-header">
              <span className="panel-icon cb">⛨</span>
              <div>
                <div className="panel-heading">Circuit Breaker</div>
                <p className="panel-caption">
                  Aísla nodos con fallas para proteger al cluster
                  {pollLatency !== null && <span className="latency-pill"> · sondeo {pollLatency} ms</span>}
                </p>
              </div>
            </div>

            {nodes.length > 0 ? (
              <div className="node-list">
                {nodes.map(node => {
                  const effective = getEffectiveCircuit(node)
                  const simulated = !!simulatedDown[node.id]
                  const anim = nodeAnim[node.id]
                  return (
                    <div
                      key={node.id}
                      className={`cb-node ${anim ? `anim-${anim}` : ''}`}
                      id={`node-${node.id}`}
                    >
                      <div className="cb-node-header">
                        <div className="cb-node-name">
                          <div className={`node-status-dot ${getCircuitClass(effective)}`}></div>
                          {node.id}
                          {simulated && <span className="sim-badge">simulado</span>}
                        </div>
                        <div className="cb-node-seq">seq: {node.seq}</div>
                      </div>
                      <div className="cb-stepper">
                        <div className={`cb-step ${getCircuitClass(effective) === 'closed' ? 'active closed' : ''}`}>
                          Activo
                        </div>
                        <span className="cb-arrow">→</span>
                        <div className={`cb-step ${getCircuitClass(effective) === 'open' ? 'active open' : ''}`}>
                          Caído
                        </div>
                        <span className="cb-arrow">→</span>
                        <div className={`cb-step ${getCircuitClass(effective) === 'half_open' ? 'active half_open' : ''}`}>
                          Verificando
                        </div>
                      </div>
                      <div className="cb-node-footer">
                        <span className="down-count-chip">Caídas: {downCounts[node.id] || 0}</span>
                        <button
                          className="simulate-btn"
                          disabled={simulated}
                          onClick={() => handleSimulateDown(node.id)}
                          title="Simulación visual local: no afecta al balanceador ni a los nodos reales"
                        >
                          {simulated ? 'Simulando caída…' : 'Simular caída'}
                        </button>
                      </div>
                    </div>
                  )
                })}
              </div>
            ) : (
              <p className="loading-text">Conectando al coordinador...</p>
            )}
          </div>
        </aside>
      </div>

      {/* Toasts */}
      <div className="toast-container">
        {toasts.map(toast => (
          <div key={toast.id} className={`toast ${toast.type}`}>
            {toast.message}
          </div>
        ))}
      </div>
    </div>
  )
}

export default App
