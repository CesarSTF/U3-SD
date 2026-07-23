# Spec: Demo web (backend + frontend)

Esto es distinto del generador de tráfico (`spec-cliente.md`, que genera carga masiva para el CSV de resultados). Esto es la **demo visual** para la sustentación: una mini red social donde se ve, en vivo, un like disparándose y el estado de los 3 nodos.

No corre en las 4 máquinas del clúster — corre aparte (tu laptop), y le habla al balanceador por su IP, igual que el generador de tráfico.

## 1. Backend (Python, FastAPI)

Es un **proxy delgado** — no tiene lógica de negocio propia, no toca Postgres, no sabe nada de cuórum. Solo:

1. Sirve una lista fija de posts en memoria (sin BD propia — no hace falta para la demo):
   ```python
   POSTS = [
     {"id": "post-1", "autor": "ana", "texto": "Mi primer post"},
     {"id": "post-2", "autor": "luis", "texto": "Otro post de prueba"},
   ]
   ```
2. Reenvía likes y lecturas al balanceador+coordinador, generando el `like_id` (uuid4) del lado del backend para que el frontend no tenga que preocuparse por eso.
3. Reenvía el `/status` del balanceador tal cual, para el dashboard.

### Endpoints

| Método | Ruta | Hace |
|---|---|---|
| GET | `/posts` | Devuelve `POSTS` (lista fija en memoria) |
| POST | `/posts/{post_id}/like` | Genera `like_id`, llama `POST {balanceador}/like`, devuelve la respuesta tal cual |
| GET | `/posts/{post_id}/likes` | Llama `GET {balanceador}/likes/{post_id}`, devuelve la respuesta tal cual |
| GET | `/status` | Llama `GET {balanceador}/status`, devuelve la respuesta tal cual |

Config: solo necesita la URL del balanceador (`BALANCEADOR_URL`, variable de entorno o `.env`).

## 2. Frontend (React + Vite)

Una sola pantalla, dos secciones, sin router:

**Feed de posts** (arriba): lista de `POSTS`, cada uno con su contador de likes (poll a `/posts/{id}/likes` cada 2s o al hacer click) y un botón "❤ Like" que llama `POST /posts/{id}/like`.

**Panel de estado del clúster** (costado o abajo): 3 indicadores, uno por nodo, coloreados según `circuit` (viene de `GET /status`, poll cada 2s):
- `CLOSED` → verde, "activo"
- `HALF_OPEN` → amarillo, "resincronizando"
- `OPEN` → rojo, "caído"

Este panel es el que hace *visible* en la sustentación lo que están explicando en el documento — cuando maten un nodo a mano durante la demo, el panel lo muestra en rojo a los pocos segundos (según `failure_threshold * interval_ms`), y los likes siguen funcionando igual.

Sin Redux, sin React Router, sin manejo de sesión — `useState` + `useEffect` con `setInterval` para el polling alcanza para las dos secciones.

## 3. Qué NO hace este componente

- No genera carga masiva ni CSV de resultados — eso es `spec-cliente.md`.
- No persiste posts ni usuarios — es una demo, no un producto.
- No tiene autenticación ni sesiones de usuario.
