# ═══════════════════════════════════════════════════════════════
# Makefile — Proyecto Sistemas Distribuidos U3
#
# Máquina 1 (coordinador — cesar):
#   make install-coordinador    → instala deps de Python + compila likes-service
#   make run-coordinador        → levanta balanceador en :8080
#   make run-cliente            → corre el generador de tráfico
#   make run-demo-backend       → backend proxy para la webapp
#   make run-demo-frontend      → frontend React (dev server)
#   make test-local             → prueba de integración 3 nodos en localhost
#
# Máquinas 2, 3, 4 (nodos — esclavos):
#   make install-nodo           → instala JDK 21 + Maven + PostgreSQL
#   make setup-db               → crea usuario y BD en Postgres
#   make build-nodo             → compila likes-service (genera el .jar)
#   make run-nodo-1             → levanta likes-service con profile node1
#   make run-nodo-2             → levanta likes-service con profile node2
#   make run-nodo-3             → levanta likes-service con profile node3
#
# Verificación rápida:
#   make status                 → muestra el estado del coordinador
#   make health                 → hace health check a los 3 nodos
# ═══════════════════════════════════════════════════════════════

.PHONY: help install-coordinador install-nodo setup-db build-nodo \
        run-coordinador run-nodo-1 run-nodo-2 run-nodo-3 \
        run-cliente run-demo-backend run-demo-frontend \
        test-local test-integracion status health clean

# Variables configurables
BALANCEADOR_PORT ?= 8080
NODE_PORT        ?= 8081
PG_USER          ?= user
PG_PASS          ?= pass
PG_DB            ?= likesdb
JAR              = likes-service/target/likes-service-1.0.0.jar

# ─────────────────────────────────────────────
# AYUDA
# ─────────────────────────────────────────────
help:
	@echo ""
	@echo "  ╔══════════════════════════════════════════════════════╗"
	@echo "  ║   Proyecto Sistemas Distribuidos — U3               ║"
	@echo "  ╠══════════════════════════════════════════════════════╣"
	@echo "  ║                                                     ║"
	@echo "  ║  COORDINADOR (máquina 1):                           ║"
	@echo "  ║    make install-coordinador                         ║"
	@echo "  ║    make run-coordinador                             ║"
	@echo "  ║    make run-cliente                                 ║"
	@echo "  ║    make run-demo-backend                            ║"
	@echo "  ║    make run-demo-frontend                           ║"
	@echo "  ║                                                     ║"
	@echo "  ║  NODOS (máquinas 2, 3, 4):                          ║"
	@echo "  ║    make install-nodo                                ║"
	@echo "  ║    make setup-db                                    ║"
	@echo "  ║    make build-nodo                                  ║"
	@echo "  ║    make run-nodo-1  (o run-nodo-2, run-nodo-3)      ║"
	@echo "  ║                                                     ║"
	@echo "  ║  PRUEBAS (localhost):                               ║"
	@echo "  ║    make test-local        (3 nodos sin balanceador) ║"
	@echo "  ║    make test-integracion  (3 nodos + balanceador)   ║"
	@echo "  ║                                                     ║"
	@echo "  ║  VERIFICACIÓN:                                      ║"
	@echo "  ║    make status            (estado del coordinador)  ║"
	@echo "  ║    make health            (health de los 3 nodos)   ║"
	@echo "  ║                                                     ║"
	@echo "  ╚══════════════════════════════════════════════════════╝"
	@echo ""

# ─────────────────────────────────────────────
# INSTALACIÓN — COORDINADOR (máquina 1)
# ─────────────────────────────────────────────
install-coordinador:
	@echo "══ Instalando dependencias del coordinador ══"
	pip install -r balanceador-coordinador/requirements.txt
	pip install -r cliente/requirements.txt
	pip install -r demo-webapp/backend/requirements.txt
	@echo ""
	@echo "══ Instalando dependencias del frontend ══"
	cd demo-webapp/frontend && npm install
	@echo ""
	@echo "══ Compilando likes-service (para pruebas locales) ══"
	cd likes-service && mvn clean package -DskipTests
	@echo ""
	@echo "✓ Coordinador listo."

# ─────────────────────────────────────────────
# INSTALACIÓN — NODO (máquinas 2, 3, 4)
# ─────────────────────────────────────────────
install-nodo:
	@echo "══ Instalando JDK 21 + Maven + PostgreSQL ══"
	@echo "Ejecutando con sudo — te va a pedir contraseña..."
	sudo apt update
	sudo apt install -y openjdk-21-jdk maven postgresql postgresql-client
	@echo ""
	@echo "══ Verificando versiones ══"
	java -version
	mvn -version | head -1
	psql --version
	@echo ""
	@echo "══ Arrancando PostgreSQL ══"
	sudo systemctl enable postgresql
	sudo systemctl start postgresql
	@echo ""
	@echo "✓ Nodo listo. Ahora ejecutá: make setup-db && make build-nodo"

# ─────────────────────────────────────────────
# SETUP BD — NODO
# ─────────────────────────────────────────────
setup-db:
	@echo "══ Creando usuario y base de datos en PostgreSQL ══"
	sudo -u postgres psql -c "CREATE USER \"$(PG_USER)\" WITH PASSWORD '$(PG_PASS)' CREATEDB;" 2>/dev/null || echo "(usuario ya existe)"
	sudo -u postgres psql -c "CREATE DATABASE $(PG_DB) OWNER \"$(PG_USER)\";" 2>/dev/null || echo "(BD ya existe)"
	@echo ""
	@echo "══ Verificando conexión ══"
	@PGPASSWORD=$(PG_PASS) psql -h localhost -U $(PG_USER) -d $(PG_DB) -c "SELECT 1 AS ok;" && echo "✓ Conexión OK" || echo "✗ Error de conexión"

# ─────────────────────────────────────────────
# COMPILAR — NODO
# ─────────────────────────────────────────────
build-nodo:
	@echo "══ Compilando likes-service ══"
	cd likes-service && mvn clean package -DskipTests
	@echo ""
	@echo "✓ JAR generado: $(JAR)"

# ─────────────────────────────────────────────
# CORRER — COORDINADOR
# ─────────────────────────────────────────────
run-coordinador:
	@echo "══ Levantando balanceador-coordinador en :$(BALANCEADOR_PORT) ══"
	cd balanceador-coordinador && python3 main.py

# ─────────────────────────────────────────────
# CORRER — NODOS (cada máquina corre UNO de estos)
# ─────────────────────────────────────────────
run-nodo-1:
	@echo "══ Levantando likes-service node-1 en :$(NODE_PORT) ══"
	cd likes-service && java -jar target/likes-service-1.0.0.jar \
		--spring.profiles.active=node1 \
		--spring.config.additional-location=file:./config/

run-nodo-2:
	@echo "══ Levantando likes-service node-2 en :$(NODE_PORT) ══"
	cd likes-service && java -jar target/likes-service-1.0.0.jar \
		--spring.profiles.active=node2 \
		--spring.config.additional-location=file:./config/

run-nodo-3:
	@echo "══ Levantando likes-service node-3 en :$(NODE_PORT) ══"
	cd likes-service && java -jar target/likes-service-1.0.0.jar \
		--spring.profiles.active=node3 \
		--spring.config.additional-location=file:./config/

# ─────────────────────────────────────────────
# CORRER — CLIENTE (generador de tráfico)
# ─────────────────────────────────────────────
run-cliente:
	@echo "══ Corriendo generador de tráfico ══"
	cd cliente && python3 main.py

# ─────────────────────────────────────────────
# CORRER — DEMO WEBAPP
# ─────────────────────────────────────────────
run-demo-backend:
	@echo "══ Levantando demo backend en :8000 ══"
	cd demo-webapp/backend && python3 main.py

run-demo-frontend:
	@echo "══ Levantando demo frontend (Vite dev server) ══"
	cd demo-webapp/frontend && npm run dev

# ─────────────────────────────────────────────
# PRUEBAS LOCALES (todo en 1 máquina)
# ─────────────────────────────────────────────
test-local:
	@echo "══ Prueba: 3 nodos en localhost (sin balanceador) ══"
	cd likes-service && ./test_3_nodos.sh

test-integracion:
	@echo "══ Prueba: 3 nodos + balanceador en localhost ══"
	cd likes-service && ./test_integracion.sh

# ─────────────────────────────────────────────
# VERIFICACIÓN RÁPIDA
# ─────────────────────────────────────────────
status:
	@echo "══ Estado del coordinador ══"
	@curl -sf http://localhost:$(BALANCEADOR_PORT)/status | python3 -m json.tool 2>/dev/null || echo "✗ Coordinador no responde en :$(BALANCEADOR_PORT)"

health:
	@echo "══ Health check de los 3 nodos ══"
	@for port in 8081 8082 8083; do \
		echo -n "  :$$port → "; \
		curl -sf http://localhost:$$port/health 2>/dev/null || echo "✗ no responde"; \
	done
	@echo ""

# ─────────────────────────────────────────────
# LIMPIEZA
# ─────────────────────────────────────────────
clean:
	@echo "══ Limpiando artefactos de build ══"
	cd likes-service && mvn clean 2>/dev/null || true
	rm -rf demo-webapp/frontend/node_modules demo-webapp/frontend/dist
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
	@echo "✓ Limpio."
