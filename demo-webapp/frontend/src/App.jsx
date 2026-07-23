import { useState, useEffect, useCallback } from 'react'
import './App.css'

const API_URL = import.meta.env.VITE_API_URL || 'http://localhost:3001'
const POLL_INTERVAL = 2000

function App() {
  const [posts, setPosts] = useState([])
  const [likeCounts, setLikeCounts] = useState({})
  const [clusterStatus, setClusterStatus] = useState(null)
  const [toasts, setToasts] = useState([])
  const [animatingHearts, setAnimatingHearts] = useState({})

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

  // --- Toast system ---
  const addToast = (message, type = 'success') => {
    const id = Date.now()
    setToasts(prev => [...prev, { id, message, type }])
    setTimeout(() => {
      setToasts(prev => prev.filter(t => t.id !== id))
    }, 3000)
  }

  // --- Like handler ---
  const handleLike = async (postId) => {
    // Trigger heart animation
    setAnimatingHearts(prev => ({ ...prev, [postId]: true }))
    setTimeout(() => setAnimatingHearts(prev => ({ ...prev, [postId]: false })), 400)

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

  const getCircuitLabel = (circuit) => {
    switch (circuit) {
      case 'CLOSED': return 'Activo'
      case 'OPEN': return 'Caido'
      case 'HALF_OPEN': return 'Resync'
      default: return circuit
    }
  }

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

        {/* Panel de estado del cluster */}
        <aside className="cluster-panel" id="cluster-panel">
          <div className="section-title">Estado del Cluster</div>
          {clusterStatus && clusterStatus.nodes ? (
            <div className="node-list">
              {clusterStatus.nodes.map(node => (
                <div key={node.id} className="node-item" id={`node-${node.id}`}>
                  <div className="node-info">
                    <div className={`node-status-dot ${getCircuitClass(node.circuit)}`}></div>
                    <span className="node-name">{node.id}</span>
                  </div>
                  <div className="node-meta">
                    <span className={`node-circuit-label ${getCircuitClass(node.circuit)}`}>
                      {getCircuitLabel(node.circuit)}
                    </span>
                    <div className="node-seq">seq: {node.seq}</div>
                  </div>
                </div>
              ))}
            </div>
          ) : (
            <p className="loading-text">Conectando al coordinador...</p>
          )}
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
