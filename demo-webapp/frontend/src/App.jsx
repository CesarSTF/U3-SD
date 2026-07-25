import { useState, useEffect, useCallback, useRef } from 'react'
import './App.css'

const API_URL = import.meta.env.VITE_API_URL || 'http://localhost:3001'
const POLL_INTERVAL = 2000
const ROUTE_ANIM_MS = 700

function App() {
  const [posts, setPosts] = useState([])
  const [likeCounts, setLikeCounts] = useState({})
  const [clusterStatus, setClusterStatus] = useState(null)
  const [toasts, setToasts] = useState([])
  const [animatingHearts, setAnimatingHearts] = useState({})

  // --- Balanceador de carga (visualización round robin del lado cliente) ---
  const [lbCounts, setLbCounts] = useState({})
  const [route, setRoute] = useState(null) // { nodeId, key }
  const rrIndexRef = useRef(0)

  // --- Fetch posts ---
  useEffect(() => {
    fetch(`${API_URL}/posts`)
      .then(r => r.json())
      .then(setPosts)
      .catch(err => console.error('Error fetching posts:', err))
  }, [])

  // --- Poll like counts ---
  const fetchLikeCounts = useCallback(() => {
    posts.forEach(post => {
      fetch(`${API_URL}/posts/${post.id}/likes`)
        .then(r => r.json())
        .then(data => {
          if (data.count !== undefined) {
            setLikeCounts(prev => ({ ...prev, [post.id]: data.count }))
          }
        })
        .catch(() => {})
    })
  }, [posts])

  useEffect(() => {
    if (posts.length === 0) return
    fetchLikeCounts()
    const interval = setInterval(fetchLikeCounts, POLL_INTERVAL)
    return () => clearInterval(interval)
  }, [posts, fetchLikeCounts])

  // --- Poll cluster status ---
  useEffect(() => {
    const fetchStatus = () => {
      fetch(`${API_URL}/status`)
        .then(r => r.json())
        .then(setClusterStatus)
        .catch(() => {})
    }
    fetchStatus()
    const interval = setInterval(fetchStatus, POLL_INTERVAL)
    return () => clearInterval(interval)
  }, [])

  // --- Limpia la animación de ruteo tras completarse ---
  useEffect(() => {
    if (!route) return
    const timeout = setTimeout(() => setRoute(null), ROUTE_ANIM_MS)
    return () => clearTimeout(timeout)
  }, [route])

  // --- Toast system ---
  const addToast = (message, type = 'success') => {
    const id = Date.now()
    setToasts(prev => [...prev, { id, message, type }])
    setTimeout(() => {
      setToasts(prev => prev.filter(t => t.id !== id))
    }, 3000)
  }

  // --- Elige el siguiente nodo elegible por round robin (mismo criterio que el balanceador real: omite nodos con el circuito abierto) ---
  const pickNextNode = () => {
    const nodes = clusterStatus?.nodes || []
    const eligible = nodes.filter(n => n.circuit === 'CLOSED')
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
  const eligibleCount = nodes.filter(n => n.circuit === 'CLOSED').length

  return (
    <div className="app-container">
      {/* Header */}
      <header className="app-header">
        <h1 className="app-title">LikeCluster</h1>
        <p className="app-subtitle">Sistema de replicas leaderless con cuorum — Demo en vivo</p>
      </header>

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
                  {nodes.map(node => (
                    <div
                      key={node.id}
                      className={`lb-row ${getLbRowClass(node.circuit)} ${route?.nodeId === node.id ? 'routing' : ''}`}
                    >
                      <div className="lb-track">
                        {route?.nodeId === node.id && <span className="lb-dot" key={route.key}></span>}
                      </div>
                      <div className="lb-node">
                        <div className="lb-node-info">
                          <span className="lb-node-name">{node.id}</span>
                          <span className={`lb-node-tag ${getLbRowClass(node.circuit)}`}>
                            {getLbTagLabel(node.circuit)}
                          </span>
                        </div>
                        <span className="lb-node-count">
                          <strong>{lbCounts[node.id] || 0}</strong> req. enviadas
                        </span>
                      </div>
                    </div>
                  ))}
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
                </p>
              </div>
            </div>

            {nodes.length > 0 ? (
              <div className="node-list">
                {nodes.map(node => (
                  <div key={node.id} className="cb-node" id={`node-${node.id}`}>
                    <div className="cb-node-header">
                      <div className="cb-node-name">
                        <div className={`node-status-dot ${getCircuitClass(node.circuit)}`}></div>
                        {node.id}
                      </div>
                      <div className="cb-node-seq">seq: {node.seq}</div>
                    </div>
                    <div className="cb-stepper">
                      <div className={`cb-step ${getCircuitClass(node.circuit) === 'closed' ? 'active closed' : ''}`}>
                        Activo
                      </div>
                      <span className="cb-arrow">→</span>
                      <div className={`cb-step ${getCircuitClass(node.circuit) === 'open' ? 'active open' : ''}`}>
                        Caído
                      </div>
                      <span className="cb-arrow">→</span>
                      <div className={`cb-step ${getCircuitClass(node.circuit) === 'half_open' ? 'active half_open' : ''}`}>
                        Verificando
                      </div>
                    </div>
                  </div>
                ))}
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
