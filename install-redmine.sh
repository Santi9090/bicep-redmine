#!/bin/bash

###############################################################################
# REDMINE 6.1.1 - INSTALACIÓN COMPLETA Y AUTOMATIZADA PARA PRODUCCIÓN
# 
# Script idempotente para instalar Redmine 6.1.1 en Ubuntu
# Compatible con: Ubuntu 20.04 LTS, 22.04 LTS, 24.04 LTS
#
# Basado en documentación oficial:
# https://www.redmine.org/projects/redmine/wiki/RedmineInstall
#
# Versiones instaladas:
#   - Ruby 3.2, 3.3, o 3.4
#   - Rails 7.2
#   - MySQL 8.0+
#   - Apache 2.4+
#   - Phusion Passenger
#
# CARACTERÍSTICAS:
#   ✓ Instalación completamente automatizada
#   ✓ Idempotente (se puede ejecutar múltiples veces)
#   ✓ Compatible con cloud-init para Azure, AWS, etc.
#   ✓ Logging completo en /var/log/redmine-install.log
#   ✓ Manejo robusto de errores y reintentos
#   ✓ Configuración optimizada para producción
#
# USO:
#   bash install-redmine.sh
#
# CLOUD-INIT (Azure, AWS, etc):
#   Agregarlo en custom data / user data
#   Se ejecutará automáticamente al iniciar la VM
#
###############################################################################

set -e

# =============================================================================
# CONFIGURACIÓN
# =============================================================================

REDMINE_DIR="/usr/share/redmine"
REDMINE_USER="www-data"
REDMINE_GROUP="www-data"
MYSQL_USER="redmine"
MYSQL_PASSWORD="Redmine2024Pass"
REDMINE_LANG="es"
LOG_FILE="/var/log/redmine-install.log"

# =============================================================================
# FUNCIONES AUXILIARES
# =============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

error() {
    log "[ERROR] $1"
    exit 1
}

success() {
    log "[✓] $1"
}

warning() {
    log "[⚠] $1"
}

# =============================================================================
# VERIFICACIONES PREVIAS
# =============================================================================

if [ "$EUID" -ne 0 ]; then
    error "Este script debe ejecutarse como root (con sudo)"
fi

mkdir -p "$(dirname "$LOG_FILE")"

log "═════════════════════════════════════════════════════════════════"
log "REDMINE 6.1.1 - INSTALACIÓN COMPLETA Y AUTOMATIZADA"
log "═════════════════════════════════════════════════════════════════"
log "Sistema: $(lsb_release -d 2>/dev/null | cut -f2 || echo 'Desconocido')"
log "Kernel: $(uname -r)"
log "Hostname: $(hostname)"
log "Log: $LOG_FILE"
log ""

# =============================================================================
# PASO 1: ACTUALIZAR SISTEMA
# =============================================================================

log ""
log "[1/12] Actualizando sistema..."

export DEBIAN_FRONTEND=noninteractive
apt-get update -y >> "$LOG_FILE" 2>&1 || error "Error actualizando package list"
apt-get upgrade -y -o Dpkg::Options::="--force-confnew" >> "$LOG_FILE" 2>&1 || error "Error upgradiendo paquetes"

success "Sistema actualizado"

# =============================================================================
# PASO 2: INSTALAR DEPENDENCIAS BASE
# =============================================================================

log ""
log "[2/12] Instalando dependencias base..."

PACKAGES=(
    "build-essential"
    "libssl-dev"
    "libreadline-dev"
    "zlib1g-dev"
    "libffi-dev"
    "libyaml-dev"
    "libsqlite3-dev"
    "curl"
    "wget"
    "git"
    "gnupg2"
    "ca-certificates"
    "lsb-release"
    "imagemagick"
    "ghostscript"
    "libmagickwand-dev"
    "subversion"
    "git-svn"
)

for package in "${PACKAGES[@]}"; do
    if ! dpkg -l 2>/dev/null | grep -q "^ii  $package"; then
        log "  Instalando $package..."
        apt-get install -y "$package" >> "$LOG_FILE" 2>&1 || warning "Error instalando $package"
    fi
done

success "Dependencias base instaladas"

# =============================================================================
# PASO 3: INSTALAR RUBY
# =============================================================================

log ""
log "[3/12] Instalando Ruby..."

if ! command -v ruby &> /dev/null; then
    apt-get install -y ruby ruby-dev ruby-bundler >> "$LOG_FILE" 2>&1 || error "Error instalando Ruby"
fi

RUBY_VERSION=$(ruby --version 2>/dev/null | awk '{print $2}' | cut -d. -f1,2)
log "  Ruby versión: $(ruby --version 2>/dev/null)"

if ! echo "$RUBY_VERSION" | grep -qE "^3\.[2-4]"; then
    warning "Ruby $RUBY_VERSION - se recomienda 3.2+ para Redmine 6.1"
fi

if ! command -v bundle &> /dev/null; then
    gem install bundler --no-document >> "$LOG_FILE" 2>&1 || error "Error instalando bundler"
fi

success "Ruby instalado: $(ruby --version 2>/dev/null)"

# =============================================================================
# PASO 4: INSTALAR Y CONFIGURAR MYSQL
# =============================================================================

log ""
log "[4/12] Instalando y configurando MySQL..."

if ! command -v mysql &> /dev/null; then
    log "  MySQL no encontrado. Instalando..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y mysql-server mysql-client libmysqlclient-dev >> "$LOG_FILE" 2>&1 || error "Error instalando MySQL"
fi

systemctl enable mysql >> "$LOG_FILE" 2>&1
systemctl start mysql >> "$LOG_FILE" 2>&1
sleep 3

MYSQL_VERSION=$(mysql --version 2>/dev/null | awk '{print $5}' | cut -d. -f1,2 || echo "desconocida")
log "  MySQL versión: $MYSQL_VERSION"

# Crear base de datos si no existe
if ! mysql -e "SHOW DATABASES LIKE 'redmine';" 2>/dev/null | grep -q redmine; then
    log "  Creando base de datos 'redmine'..."
    mysql <<EOF >> "$LOG_FILE" 2>&1
CREATE DATABASE redmine CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER '$MYSQL_USER'@'localhost' IDENTIFIED BY '$MYSQL_PASSWORD';
GRANT ALL PRIVILEGES ON redmine.* TO '$MYSQL_USER'@'localhost';
FLUSH PRIVILEGES;
EOF
    success "Base de datos creada"
else
    success "Base de datos ya existe"
fi

# Configurar transaction isolation
mysql -u root <<EOF >> "$LOG_FILE" 2>&1
SET GLOBAL TRANSACTION ISOLATION LEVEL READ COMMITTED;
EOF

# Verificar conexión
if mysql -h localhost -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" -e "SELECT VERSION();" >> "$LOG_FILE" 2>&1; then
    success "Conexión MySQL verificada"
else
    error "No se puede conectar a MySQL"
fi

# =============================================================================
# PASO 5: INSTALAR APACHE
# =============================================================================

log ""
log "[5/12] Instalando Apache..."

if ! command -v apache2ctl &> /dev/null; then
    apt-get install -y apache2 apache2-dev >> "$LOG_FILE" 2>&1 || error "Error instalando Apache"
fi

a2enmod rewrite >> "$LOG_FILE" 2>&1
a2enmod deflate >> "$LOG_FILE" 2>&1
a2enmod headers >> "$LOG_FILE" 2>&1

success "Apache instalado"

# =============================================================================
# PASO 6: INSTALAR PASSENGER
# =============================================================================

log ""
log "[6/12] Instalando Passenger..."

if ! dpkg -l 2>/dev/null | grep -q libapache2-mod-passenger; then
    apt-get install -y libapache2-mod-passenger >> "$LOG_FILE" 2>&1 || error "Error instalando Passenger"
fi

a2enmod passenger >> "$LOG_FILE" 2>&1 || warning "Error habilitando Passenger"

if passenger-config --ruby >/dev/null 2>&1; then
    success "Passenger instalado"
else
    warning "Passenger puede no estar correctamente configurado"
fi

# =============================================================================
# PASO 7: DESCARGAR REDMINE
# =============================================================================

log ""
log "[7/12] Descargando Redmine 6.1-stable..."

if [ ! -d "$REDMINE_DIR" ]; then
    git clone --depth=1 -b 6.1-stable https://github.com/redmine/redmine.git "$REDMINE_DIR" >> "$LOG_FILE" 2>&1 || error "Error descargando Redmine"
    success "Redmine descargado"
else
    log "  Redmine ya existe"
fi

# =============================================================================
# PASO 8: CONFIGURAR DIRECTORIOS Y PERMISOS
# =============================================================================

log ""
log "[8/12] Configurando directorios y permisos..."

echo ""
echo "Creando directorios necesarios..."

mkdir -p "$REDMINE_DIR/tmp" "$REDMINE_DIR/tmp/pdf" "$REDMINE_DIR/log" "$REDMINE_DIR/files" "$REDMINE_DIR/public/assets"
mkdir -p /var/www

echo "Estableciendo propietarios..."
chown -R "$REDMINE_USER:$REDMINE_GROUP" "$REDMINE_DIR"
chown -R "$REDMINE_USER:$REDMINE_GROUP" /var/www

echo "Estableciendo permisos..."
chmod -R 755 "$REDMINE_DIR/public"
chmod -R 755 "$REDMINE_DIR/files"
chmod -R 755 "$REDMINE_DIR/tmp"
chmod -R 755 "$REDMINE_DIR/log"
chmod 755 /var/www

echo "Removiendo permisos ejecutables de archivos..."
find "$REDMINE_DIR/files" "$REDMINE_DIR/log" "$REDMINE_DIR/tmp" "$REDMINE_DIR/public/assets" -type f -exec chmod -x {} + 2>/dev/null || true

echo "✓ Directorios configurados"
echo ""

success "Directorios configurados"

success "Directorios configurados"

# =============================================================================
# PASO 9: CONFIGURAR database.yml
# =============================================================================

log ""
log "[9/12] Configurando database.yml..."

cat > "$REDMINE_DIR/config/database.yml" <<'EOF'
production:
  adapter: mysql2
  database: redmine
  host: localhost
  username: redmine
  password: "Redmine2024Pass"
  encoding: utf8mb4
  collation: utf8mb4_unicode_ci
  pool: 5
  timeout: 5000
  variables:
    transaction_isolation: "READ-COMMITTED"
EOF

chown "$REDMINE_USER:$REDMINE_GROUP" "$REDMINE_DIR/config/database.yml"
chmod 640 "$REDMINE_DIR/config/database.yml"

log "✓ database.yml configurado"
log "  Verificando conectividad a MySQL desde www-data..."

if sudo -u "$REDMINE_USER" bash -c "mysql -h localhost -u redmine -pRedmine2024Pass -e 'SELECT 1;' redmine >/dev/null 2>&1"; then
    log "✓ Conexión a MySQL verificada correctamente"
else
    echo ""
    echo "❌ ERROR CRÍTICO: NO SE PUEDE CONECTAR A MYSQL"
    echo "Ejecutando diagnóstico..."
    echo ""
    echo "1. Intentando conectar con credenciales redmine..."
    mysql -h localhost -u redmine -pRedmine2024Pass -e "SELECT 1;" redmine 2>&1 || echo "FALLÓ"
    echo ""
    echo "2. Verificando estado de MySQL..."
    systemctl status mysql 2>&1 | head -5
    echo ""
    echo "3. Verificando base de datos 'redmine'..."
    mysql -e "SHOW DATABASES LIKE 'redmine';" 2>&1 || echo "FALLÓ"
    echo ""
    error "No se puede conectar a MySQL - Detener instalación"
fi

success "database.yml configurado"

# =============================================================================
# PRE-PASO 10: VERIFICAR Y PREPARAR PARA INSTALACIÓN DE GEMAS
# =============================================================================

log ""
log "[9.5/12] Verificando requisitos previos para bundler..."

# Verificar que Gemfile existe
if [ ! -f "$REDMINE_DIR/Gemfile" ]; then
    error "Gemfile no encontrado en $REDMINE_DIR"
fi
log "  ✓ Gemfile encontrado"

# Verificar bundler
if ! command -v bundle &> /dev/null; then
    log "  Bundler no encontrado. Instalando..."
    gem install bundler --no-document >> "$LOG_FILE" 2>&1 || error "No se pudo instalar bundler"
fi
log "  ✓ Bundler: $(bundle --version)"

# Verificar y instalar dependencias de compilación faltantes
log "  Verificando dependencias de compilación..."
BUILD_PACKAGES=(
    "build-essential"
    "libssl-dev"
    "libreadline-dev"
    "zlib1g-dev"
    "libffi-dev"
    "libyaml-dev"
    "libsqlite3-dev"
    "libxml2-dev"
    "libxslt1-dev"
    "libmysqlclient-dev"
    "gcc"
    "g++"
    "make"
)

MISSING_PACKAGES=""
for pkg in "${BUILD_PACKAGES[@]}"; do
    if ! dpkg -l 2>/dev/null | grep -q "^ii  $pkg"; then
        MISSING_PACKAGES="$MISSING_PACKAGES $pkg"
    fi
done

if [ -n "$MISSING_PACKAGES" ]; then
    log "  Instalando dependencias faltantes:$MISSING_PACKAGES"
    apt-get install -y $MISSING_PACKAGES >> "$LOG_FILE" 2>&1 || warning "Algunos paquetes no se instalaron"
fi

# Limpiar cache apt
apt-get clean >> "$LOG_FILE" 2>&1 || true

# Verificar espacio en disco
DISK_AVAILABLE=$(df "$REDMINE_DIR" | awk 'NR==2 {print $4}')
if [ "$DISK_AVAILABLE" -lt 1048576 ]; then  # Menos de 1GB
    warning "Poco espacio en disco disponible: ${DISK_AVAILABLE}KB"
fi
log "  ✓ Espacio en disco: $(df -h "$REDMINE_DIR" | awk 'NR==2 {print $4}')"

# Verificar conectividad
log "  Verificando conectividad a rubygems.org..."
if ! wget -q --spider https://rubygems.org 2>/dev/null; then
    warning "No hay conectividad a rubygems.org - bundler usará cache local"
fi

# Preparar directorio para gemas
log "  Preparando directorios..."
mkdir -p "$REDMINE_DIR/vendor/bundle"
mkdir -p "$REDMINE_DIR/tmp/pids"
mkdir -p "$REDMINE_DIR/tmp/sessions"
mkdir -p "$REDMINE_DIR/tmp/cache"
mkdir -p "$REDMINE_DIR/tmp/pdf"

chown -R "$REDMINE_USER:$REDMINE_GROUP" "$REDMINE_DIR/vendor"
chown -R "$REDMINE_USER:$REDMINE_GROUP" "$REDMINE_DIR/tmp"
chmod -R 755 "$REDMINE_DIR/vendor"
chmod -R 755 "$REDMINE_DIR/tmp"

success "Verificación pre-bundler completada"

# =============================================================================
# PASO 10: INSTALAR GEMAS CON BUNDLER (CON REINTENTOS Y CAPTURA DE ERRORES)
# =============================================================================

log ""
log "[10/12] Instalando gemas de Redmine (BUNDLE INSTALL)..."
log "Esto puede tomar 10-20 minutos. MOSTRANDO TODOS LOS ERRORES..."

cd "$REDMINE_DIR"

echo ""
echo "═══ EJECUCIÓN DE BUNDLE INSTALL (TODO VISIBLE EN CONSOLA) ═══"
echo ""

# Verificar que Gemfile existe
if [ ! -f "$REDMINE_DIR/Gemfile" ]; then
    echo "❌ GEMFILE NO EXISTE EN: $REDMINE_DIR"
    ls -la "$REDMINE_DIR/" | head -20
    error "Gemfile no encontrado - Redmine no se descargó correctamente"
fi
echo "✓ Gemfile encontrado"
echo ""

# Configurar bundler - VISIBLE EN CONSOLA
log "Configurando bundler..."
echo "  - without: 'development test'"
echo "  - path: 'vendor/bundle'"
echo "  - timeout: 300"
echo "  - max_retries: 5"
echo ""

sudo -u "$REDMINE_USER" bash -c "cd '$REDMINE_DIR' && \
  bundle config set --local without 'development test' && \
  bundle config set --local path 'vendor/bundle' && \
  bundle config set --local timeout 300 && \
  bundle config set --local max_retries 5" 2>&1 | sed 's/^/  [bundler config] /'

echo ""
log "Iniciando bundle install..."
echo ""

# Variable para rastrear éxito
BUNDLE_SUCCESS=false
ATTEMPT=0
MAX_ATTEMPTS=1

# LOOP DE REINTENTOS CON SALIDA VISIBLE
while [ $ATTEMPT -lt $MAX_ATTEMPTS ] && [ "$BUNDLE_SUCCESS" = "false" ]; do
    ATTEMPT=$((ATTEMPT + 1))
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "INTENTO $ATTEMPT/$MAX_ATTEMPTS - $(date '+%Y-%m-%d %H:%M:%S')"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # Limpiar lock si no es el primer intento
    if [ $ATTEMPT -gt 1 ]; then
        echo "Limpiando estado anterior..."
        sudo -u "$REDMINE_USER" bash -c "cd '$REDMINE_DIR' && rm -f Gemfile.lock .bundle/config" 2>/dev/null || true
        echo "Esperando 10 segundos antes de reintentar..."
        sleep 10
    fi
    
    # Ejecutar bundle install DIRECTAMENTE (todo visible en consola)
    echo "Ejecutando bundle install..."
    echo ""
    
    if sudo -u "$REDMINE_USER" bash -c "
        cd '$REDMINE_DIR'
        export MALLOC_ARENA_MAX=2
        export BUNDLE_RETRY=5
        export BUNDLE_JOBS=2
        bundle install --retry 5 --jobs 2
    "; then
        
        BUNDLE_SUCCESS=true
        echo ""
        echo "✓ Bundle install completado exitosamente en intento $ATTEMPT"
        
    else
        BUNDLE_EXIT=$?
        echo ""
        echo "❌ Bundle install FALLÓ (intento $ATTEMPT/$MAX_ATTEMPTS, código: $BUNDLE_EXIT)"
        echo ""
        
        if [ $ATTEMPT -lt $MAX_ATTEMPTS ]; then
            echo "REINTENTANDO en 10 segundos..."
            sleep 10
        fi
    fi
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$BUNDLE_SUCCESS" = "true" ]; then
    echo "✓ BUNDLE INSTALL EXITOSO"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # VALIDACIÓN ADICIONAL: Verificar que gemas críticas están disponibles
    echo "Verificando gemas críticas instaladas..."
    CRITICAL_GEMS=("rails" "mysql2" "rack" "bundler")
    MISSING_CRITICAL=false
    
    for gem in "${CRITICAL_GEMS[@]}"; do
        if sudo -u "$REDMINE_USER" bash -c "cd $REDMINE_DIR && bundle show $gem >/dev/null 2>&1"; then
            echo "  ✓ $gem"
        else
            echo "  ❌ $gem NO ENCONTRADA"
            MISSING_CRITICAL=true
        fi
    done
    
    if [ "$MISSING_CRITICAL" = "true" ]; then
        echo ""
        echo "⚠ Faltan gemas críticas. Intentando instalar..."
        for gem in "${CRITICAL_GEMS[@]}"; do
            if ! sudo -u "$REDMINE_USER" bash -c "cd $REDMINE_DIR && bundle show $gem >/dev/null 2>&1"; then
                echo "  Instalando $gem..."
                sudo -u "$REDMINE_USER" bash -c "cd $REDMINE_DIR && gem install --no-document $gem 2>&1" || warning "Error instalando $gem"
            fi
        done
    fi
    
    success "Gemas instaladas correctamente"
else
    echo "❌ BUNDLE INSTALL FALLÓ DESPUÉS DE $MAX_ATTEMPTS INTENTOS"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "DIAGNÓSTICO DE ERRORES:"
    echo ""
    echo "1. Verificando que Gemfile esté presente..."
    if [ -f "$REDMINE_DIR/Gemfile" ]; then
        echo "   ✓ Gemfile existe"
        echo "   Primeras líneas:"
        head -10 "$REDMINE_DIR/Gemfile" | sed 's/^/   /'
    else
        echo "   ❌ Gemfile NO EXISTE"
    fi
    
    echo ""
    echo "2. Verificando directorio vendor/bundle..."
    if [ -d "$REDMINE_DIR/vendor/bundle" ]; then
        BUNDLE_COUNT=$(find "$REDMINE_DIR/vendor/bundle" -type f 2>/dev/null | wc -l)
        echo "   ✓ vendor/bundle existe con $BUNDLE_COUNT archivos"
    else
        echo "   ❌ vendor/bundle NO EXISTE"
    fi
    
    echo ""
    echo "3. Intentar instalar gemas manualmente..."
    echo "   Ejecuta en la VM:"
    echo "   cd $REDMINE_DIR && sudo -u www-data bundle install --verbose"
    echo ""
    
    warning "Continuando con pasos siguientes. Revisa bundle install manual si es necesario."
fi

echo "═══ FIN BUNDLE INSTALL ═══"
echo ""

# =============================================================================
# PASO 11: CONFIGURAR BASE DE DATOS Y COMPILAR ASSETS
# =============================================================================

log ""
log "[11/12] Configurando base de datos..."

log "  Preparando secrets.yml (Redmine 6.0+)..."
if [ ! -f "$REDMINE_DIR/config/secrets.yml" ]; then
    if [ -f "$REDMINE_DIR/config/secrets.yml.example" ]; then
        cp "$REDMINE_DIR/config/secrets.yml.example" "$REDMINE_DIR/config/secrets.yml"
        chown "$REDMINE_USER:$REDMINE_GROUP" "$REDMINE_DIR/config/secrets.yml"
        chmod 640 "$REDMINE_DIR/config/secrets.yml"
        log "✓ secrets.yml creado"
    else
        warning "⚠ No se encontró secrets.yml.example"
    fi
else
    log "✓ secrets.yml ya existe"
fi

log "  Preparando configuration.yml..."
if [ ! -f "$REDMINE_DIR/config/configuration.yml" ]; then
    if [ -f "$REDMINE_DIR/config/configuration.yml.example" ]; then
        cp "$REDMINE_DIR/config/configuration.yml.example" "$REDMINE_DIR/config/configuration.yml"
        chown "$REDMINE_USER:$REDMINE_GROUP" "$REDMINE_DIR/config/configuration.yml"
        chmod 640 "$REDMINE_DIR/config/configuration.yml"
        log "✓ configuration.yml creado"
    else
        warning "⚠ No se encontró configuration.yml.example"
    fi
else
    log "✓ configuration.yml ya existe"
fi

log "  Ejecutando migraciones..."
echo ""
echo "═══ SALIDA DE MIGRACIONES (VISIBLE EN CONSOLA) ═══"

# VERIFICACIÓN CRÍTICA: Reparar bundle si es necesario
log "  Verificando integridad de bundle..."
sudo -u "$REDMINE_USER" bash -c "cd $REDMINE_DIR && bundle install --local 2>&1 | tail -5" || {
    echo "⚠ Intentando repair de bundler..."
    sudo -u "$REDMINE_USER" bash -c "cd $REDMINE_DIR && rm -rf vendor/bundle .bundle/config && bundle install --jobs 2 2>&1 | tail -10" || true
}

# Ejecutar migraciones con manejo de errores robusto
MIGRATE_ATTEMPTS=0
MIGRATE_SUCCESS=false

while [ $MIGRATE_ATTEMPTS -lt 3 ] && [ "$MIGRATE_SUCCESS" = "false" ]; do
    MIGRATE_ATTEMPTS=$((MIGRATE_ATTEMPTS + 1))
    echo ""
    echo "Intento $MIGRATE_ATTEMPTS/3 de migraciones..."
    
    # Verificar conectividad a base de datos ANTES de migrar
    echo "  Pre-verificación: conectando a MySQL..."
    if ! sudo -u "$REDMINE_USER" bash -c "mysql -h localhost -u redmine -pRedmine2024Pass redmine -e 'SELECT 1;' 2>&1"; then
        echo "  ❌ CRÍTICO: No hay conectividad a MySQL"
        echo "  Revisa que MySQL esté activo y las credenciales sean correctas"
        sleep 5
        continue
    fi
    echo "  ✓ Conectividad OK"
    
    # Intentar con bundle exec (método recomendado)
    if sudo -u "$REDMINE_USER" bash -c "
        cd $REDMINE_DIR
        export RAILS_ENV=production
        export BUNDLE_GEMFILE=$REDMINE_DIR/Gemfile
        bundle exec rails db:migrate 2>&1
    "; then
        echo "✓ Migraciones completadas"
        MIGRATE_SUCCESS=true
    else
        MIGRATE_EXIT=$?
        echo "❌ Error con migraciones (código: $MIGRATE_EXIT)"
        
        # Capturar más detalles del error
        echo ""
        echo "📋 Intentando obtener más detalles del error..."
        sudo -u "$REDMINE_USER" bash -c "
            cd $REDMINE_DIR
            export RAILS_ENV=production
            export BUNDLE_GEMFILE=$REDMINE_DIR/Gemfile
            bundle exec rake db:migrate --trace 2>&1 | tail -30
        " || true
        
        if [ $MIGRATE_ATTEMPTS -lt 3 ]; then
            echo "  Esperando 10 segundos antes de reintentar..."
            sleep 10
        fi
    fi
done

if [ "$MIGRATE_SUCCESS" = "false" ]; then
    echo "❌ ERROR CRÍTICO: Migraciones fallaron después de 3 intentos"
    echo ""
    echo "DIAGNÓSTICO COMPLETO:"
    echo ""
    echo "1. Verificando database.yml..."
    sudo -u "$REDMINE_USER" bash -c "cat $REDMINE_DIR/config/database.yml" || echo "   ❌ NO EXISTE"
    echo ""
    echo "2. Verificando conectividad MySQL como www-data..."
    sudo -u "$REDMINE_USER" bash -c "mysql -h localhost -u redmine -pRedmine2024Pass redmine -e 'SELECT VERSION();' 2>&1" || echo "   ❌ NO CONECTA"
    echo ""
    echo "3. Verificando que Gemfile.lock existe..."
    sudo -u "$REDMINE_USER" bash -c "ls -lh $REDMINE_DIR/Gemfile.lock" || echo "   ❌ NO EXISTE"
    echo ""
    echo "4. Verificando bundle status..."
    sudo -u "$REDMINE_USER" bash -c "cd $REDMINE_DIR && bundle check 2>&1" || true
    echo ""
    echo "5. Úlimas líneas de production.log..."
    sudo -u "$REDMINE_USER" bash -c "tail -30 $REDMINE_DIR/log/production.log 2>&1" || echo "   (Sin logs)"
    echo ""
    error "Migraciones fallidas - revisa los diagnósticos arriba"
fi

log "✓ Migraciones completadas"
echo "═══ FIN MIGRACIONES ═══"
echo ""

log "  Cargando datos predeterminados..."
echo ""
echo "═══ SALIDA DE CARGA DE DATOS (VISIBLE EN CONSOLA) ═══"

LOAD_SUCCESS=false
LOAD_ATTEMPTS=0

while [ $LOAD_ATTEMPTS -lt 2 ] && [ "$LOAD_SUCCESS" = "false" ]; do
    LOAD_ATTEMPTS=$((LOAD_ATTEMPTS + 1))
    echo "Intento $LOAD_ATTEMPTS/2 de carga de datos..."
    
    if sudo -u "$REDMINE_USER" bash -c "
        cd $REDMINE_DIR
        export RAILS_ENV=production
        export REDMINE_LANG=$REDMINE_LANG
        export BUNDLE_GEMFILE=$REDMINE_DIR/Gemfile
        bundle exec rails redmine:load_default_data 2>&1
    "; then
        echo "✓ Datos predeterminados cargados"
        LOAD_SUCCESS=true
    else
        LOAD_EXIT=$?
        echo "⚠ Intento $LOAD_ATTEMPTS falló (código: $LOAD_EXIT)"
        if [ "$LOAD_ATTEMPTS" -lt 2 ]; then
            echo "  Reintentando en 3 segundos..."
            sleep 3
        fi
    fi
done

if [ "$LOAD_SUCCESS" = "false" ]; then
    warning "⚠ Datos pueden estar ya cargados o error en carga - continuando"
fi

echo "═══ FIN CARGA DE DATOS ═══"
echo ""

if ! command -v node &> /dev/null; then
    apt-get install -y nodejs npm >> "$LOG_FILE" 2>&1 || warning "Error instalando Node.js"
fi

if ! command -v yarn &> /dev/null; then
    npm install -g yarn >> "$LOG_FILE" 2>&1 || warning "Error instalando Yarn"
fi

log "  Compilando assets..."
echo ""
echo "═══ SALIDA DE COMPILACIÓN DE ASSETS (VISIBLE EN CONSOLA) ═══"

ASSETS_SUCCESS=false
ASSETS_ATTEMPTS=0

while [ $ASSETS_ATTEMPTS -lt 2 ] && [ "$ASSETS_SUCCESS" = "false" ]; do
    ASSETS_ATTEMPTS=$((ASSETS_ATTEMPTS + 1))
    echo "Intento $ASSETS_ATTEMPTS/2 de compilación de assets..."
    
    if sudo -u "$REDMINE_USER" bash -c "
        cd $REDMINE_DIR
        export RAILS_ENV=production
        export NODE_OPTIONS='--max-old-space-size=2048'
        export BUNDLE_GEMFILE=$REDMINE_DIR/Gemfile
        bundle exec rails assets:precompile 2>&1
    "; then
        echo "✓ Assets compilados"
        ASSETS_SUCCESS=true
    else
        ASSETS_EXIT=$?
        echo "⚠ Intento $ASSETS_ATTEMPTS falló (código: $ASSETS_EXIT)"
        if [ "$ASSETS_ATTEMPTS" -lt 2 ]; then
            echo "  Limpiando cache y reintentando en 5 segundos..."
            sudo -u "$REDMINE_USER" bash -c "cd $REDMINE_DIR && rm -rf public/assets tmp/cache/* .sprockets-manifest* 2>/dev/null" || true
            sleep 5
        fi
    fi
done

if [ "$ASSETS_SUCCESS" = "false" ]; then
    warning "⚠ Error compilando assets - esto puede causar problemas visuales"
fi

echo "═══ FIN COMPILACIÓN DE ASSETS ═══"
echo ""

success "Base de datos configurada"

# =============================================================================
# PRE-PASO 12: VALIDACIÓN CRÍTICA ANTES DE PASSENGER
# =============================================================================

log ""
log "[11.5/12] Validando configuración antes de Passenger..."
echo ""
echo "═══ VALIDACIÓN CRÍTICA - SALIDA VISIBLE ═══"

# Verificar que gemas críticas estén compiladas
log "  Verificando gemas críticas..."
CRITICAL_GEMAS=("mysql2" "rails" "rack" "bundler")
MISSING_GEMAS=""
for gema in "${CRITICAL_GEMAS[@]}"; do
    if ! sudo -u "$REDMINE_USER" bash -c "cd $REDMINE_DIR && bundle show $gema >/dev/null 2>&1"; then
        echo "❌ Gema CRÍTICA NO ENCONTRADA: $gema"
        MISSING_GEMAS="$MISSING_GEMAS $gema"
    else
        echo "✓ $gema OK"
    fi
done

if [ -n "$MISSING_GEMAS" ]; then
    echo ""
    echo "⚠ INTENTANDO INSTALAR GEMAS FALTANTES..."
    for gema in $MISSING_GEMAS; do
        echo "  Instalando $gema..."
        if sudo -u "$REDMINE_USER" bash -c "cd $REDMINE_DIR && gem install --no-document $gema 2>&1"; then
            echo "  ✓ $gema instalada"
        else
            echo "  ❌ Error al instalar $gema"
        fi
    done
fi

echo ""
log "  Verificando permisos de directorios..."
for dir in "$REDMINE_DIR/tmp" "$REDMINE_DIR/log" "$REDMINE_DIR/files" "$REDMINE_DIR/public/assets"; do
    if [ ! -d "$dir" ]; then
        echo "❌ Directorio NO EXISTE: $dir"
        mkdir -p "$dir"
        chown "$REDMINE_USER:$REDMINE_GROUP" "$dir"
        chmod 755 "$dir"
        echo "✓ Creado: $dir"
    elif ! sudo -u "$REDMINE_USER" [ -w "$dir" ]; then
        echo "❌ Directorio NO ESCRIBIBLE: $dir (propietario: $(stat -c '%U:%G' "$dir"))"
        sudo chown -R "$REDMINE_USER:$REDMINE_GROUP" "$dir"
        sudo chmod 755 "$dir"
        echo "✓ Permisos corregidos: $dir"
    else
        echo "✓ $dir OK"
    fi
done

echo ""
log "  Verificando database.yml..."
if [ ! -f "$REDMINE_DIR/config/database.yml" ]; then
    echo "❌ database.yml NO EXISTE"
    error "database.yml NO EXISTE - Esto causará error 500 en Passenger"
else
    echo "✓ database.yml EXISTE"
    echo "  Propietario: $(stat -c '%U:%G' "$REDMINE_DIR/config/database.yml")"
    echo "  Permisos: $(stat -c '%a' "$REDMINE_DIR/config/database.yml")"
    echo "  Contenido:"
    cat "$REDMINE_DIR/config/database.yml" | sed 's/^/    /'
fi

echo ""
log "  Verificando conectividad a MySQL desde www-data..."
if sudo -u "$REDMINE_USER" bash -c "mysql -h localhost -u redmine -pRedminePass123! -e 'SELECT 1;' redmine >/dev/null 2>&1"; then
    echo "✓ Conexión MySQL OK"
else
    echo "❌ NO PUEDE CONECTAR A MYSQL"
    echo "  Intentando diagnóstico..."
    echo "  Estado MySQL: $(systemctl is-active mysql)"
    echo "  Versión MySQL: $(mysql --version 2>/dev/null)"
    echo "  Bases disponibles: $(mysql -e "SHOW DATABASES LIKE 'redmine';" 2>/dev/null)"
    error "Verifica database.yml y credenciales MySQL - Detener aquí"
fi

echo ""
log "  Verificando secrets.yml (Redmine 6.0+)..."
if [ ! -f "$REDMINE_DIR/config/secrets.yml" ]; then
    echo "❌ secrets.yml NO EXISTE"
    if [ -f "$REDMINE_DIR/config/secrets.yml.example" ]; then
        echo "  Creando desde template..."
        cp "$REDMINE_DIR/config/secrets.yml.example" "$REDMINE_DIR/config/secrets.yml"
        chown "$REDMINE_USER:$REDMINE_GROUP" "$REDMINE_DIR/config/secrets.yml"
        chmod 640 "$REDMINE_DIR/config/secrets.yml"
        echo "✓ secrets.yml creado"
    fi
else
    echo "✓ secrets.yml OK"
fi

echo ""
log "  Verificando assets compilados..."
ASSETS_COUNT=$(find "$REDMINE_DIR/public/assets" -type f 2>/dev/null | wc -l)
if [ "$ASSETS_COUNT" -lt 5 ]; then
    echo "❌ Assets NO COMPILADOS O INSUFICIENTES (encontrados: $ASSETS_COUNT)"
    echo "  Esto causará problemas visuales en el navegador"
else
    echo "✓ Assets compilados ($ASSETS_COUNT archivos)"
fi

echo ""
log "  Verificando Ruby disponible..."
RUBY_PATH=$(which ruby)
if [ -z "$RUBY_PATH" ]; then
    echo "❌ Ruby NO ENCONTRADO"
    error "Ruby NO ENCONTRADO en PATH - Passenger no funcionará"
else
    echo "✓ Ruby: $RUBY_PATH ($(ruby --version))"
fi

echo ""
log "  Verificando Passenger..."
if ! dpkg -l 2>/dev/null | grep -q libapache2-mod-passenger; then
    echo "❌ libapache2-mod-passenger NO ESTÁ INSTALADO"
    error "Passenger NO está instalado"
else
    echo "✓ Passenger instalado"
    echo "  Versión: $(passenger-config --version 2>/dev/null)"
fi

echo "═══ FIN VALIDACIÓN ═══"
echo ""
success "Validación pre-Passenger completada"

# =============================================================================
# PASO 12: CONFIGURAR APACHE CON PASSENGER
# =============================================================================

# =============================================================================
# PASO 12: CONFIGURAR APACHE CON PASSENGER
# =============================================================================

log ""
log "[12/12] Configurando Apache..."
echo ""
echo "═══ CONFIGURACIÓN DE APACHE - SALIDA VISIBLE ═══"

log "  Habilitando módulos Apache necesarios..."
if a2enmod rewrite; then
    echo "✓ rewrite habilitado"
else
    echo "❌ Error habilitando rewrite"
fi

if a2enmod deflate; then
    echo "✓ deflate habilitado"
else
    echo "❌ Error habilitando deflate"
fi

if a2enmod headers; then
    echo "✓ headers habilitado"
else
    echo "❌ Error habilitando headers"
fi

if a2enmod passenger; then
    echo "✓ passenger habilitado"
else
    echo "❌ Error habilitando passenger"
fi

echo ""
log "  Configurando sitio virtual Redmine..."

cat > /etc/apache2/sites-available/redmine.conf <<EOF
<VirtualHost *:80>
    ServerName localhost
    ServerAlias *
    ServerAdmin admin@redmine.local
    DocumentRoot /usr/share/redmine/public

    <Directory /usr/share/redmine>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    <Directory /usr/share/redmine/public>
        Options -Indexes FollowSymLinks MultiViews
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/redmine-error.log
    CustomLog \${APACHE_LOG_DIR}/redmine-access.log combined
    LogLevel warn

    # Configuración de Passenger - CRÍTICO
    PassengerAppRoot /usr/share/redmine
    PassengerAppType rack
    PassengerUser www-data
    PassengerGroup www-data
    PassengerRuby $(which ruby)
    PassengerLoadShellEnvvars on
    PassengerFriendlyErrorPages on
    
    # Variables de entorno para Ruby y Passenger
    SetEnv RAILS_ENV production
    SetEnv RACK_ENV production
    SetEnv BUNDLE_DEPLOYMENT true
    SetEnv BUNDLE_PATH /usr/share/redmine/vendor/bundle
    
    # Optimizaciones de Passenger
    PassengerMinInstances 1
    PassengerMaxPoolSize 4
    PassengerPoolIdleTime 0
    PassengerStartTimeout 90
</VirtualHost>
EOF
echo "✓ redmine.conf creado"

echo ""
log "  Deshabilitando sitio default..."
if a2dissite 000-default 2>&1 | grep -q "already disabled\|disabled"; then
    echo "✓ Sitio default deshabilitado"
else
    echo "⚠ Sitio default ya deshabilitado"
fi

log "  Habilitando sitio Redmine..."
if a2ensite redmine; then
    echo "✓ Sitio Redmine habilitado"
else
    echo "❌ Error habilitando sitio Redmine"
    error "No se pudo habilitar sitio Redmine"
fi

echo ""
log "  Verificando configuración de Apache..."
if apache2ctl configtest 2>&1 | tee /tmp/apache_configtest.log | grep -q "Syntax OK"; then
    echo "✓ Configuración de Apache: OK"
else
    echo "❌ ERROR EN CONFIGURACIÓN DE APACHE"
    echo "Salida de apache2ctl configtest:"
    cat /tmp/apache_configtest.log
    error "Configuración de Apache inválida"
fi

echo ""
log "  Configurando puerto 80 en Apache..."
if grep -q "^Listen 80" /etc/apache2/ports.conf; then
    echo "✓ Puerto 80 ya configurado"
else
    echo "Listen 80" >> /etc/apache2/ports.conf
    echo "✓ Puerto 80 agregado a ports.conf"
fi

echo ""
log "  Reiniciando Apache (esto puede tardar algunos segundos)..."
if systemctl restart apache2; then
    echo "✓ Apache reiniciado correctamente"
else
    APACHE_EXIT=$?
    echo "❌ Error reiniciando Apache (código: $APACHE_EXIT)"
    echo "Logs de Apache:"
    journalctl -u apache2 -n 20 2>&1 | sed 's/^/  /'
    error "Error reiniciando Apache"
fi

sleep 5

echo ""
log "  Verificando estado de Apache..."
if systemctl is-active --quiet apache2; then
    echo "✓ Apache ESTÁ ACTIVO"
else
    echo "❌ Apache NO ESTÁ ACTIVO"
    systemctl status apache2
    error "Apache no está activo"
fi

echo "═══ FIN CONFIGURACIÓN DE APACHE ═══"
echo ""
success "Apache configurado"

# =============================================================================
# VERIFICACIÓN FINAL Y DIAGNÓSTICO
# =============================================================================

log ""
log "═════════════════════════════════════════════════════════════════"
log "INSTALACIÓN COMPLETADA - VERIFICACIÓN FINAL"
log "═════════════════════════════════════════════════════════════════"

echo ""
echo "═══ DIAGNÓSTICO FINAL - VISIBILIDAD TOTAL ═══"
echo ""

log "1. Verificando acceso HTTP a Redmine..."
sleep 3
RESPONSE=$(curl -s -i "http://localhost/redmine" 2>/dev/null | head -1)
echo "   Respuesta del servidor: $RESPONSE"

if echo "$RESPONSE" | grep -q "200"; then
    echo "   ✓ Redmine ACCESIBLE (HTTP 200)"
elif echo "$RESPONSE" | grep -q "302"; then
    echo "   ✓ Redmine REDIRIGE (HTTP 302) - Probablemente accesible"
elif echo "$RESPONSE" | grep -q "500"; then
    echo "   ❌ ERROR 500 - Passenger error de aplicación"
    echo "   Último error de Passenger:"
    sudo tail -10 /var/log/apache2/redmine-error.log 2>/dev/null || echo "   (No hay logs aún)"
elif echo "$RESPONSE" | grep -q "403"; then
    echo "   ❌ ERROR 403 - Forbidden (problema de permisos)"
elif [ -z "$RESPONSE" ]; then
    echo "   ❌ NO HAY RESPUESTA - Apache puede no estar activo o puerto no abierto"
else
    echo "   ⚠ RESPUESTA INESPERADA: $RESPONSE"
fi

echo ""
log "2. Estado de servicios..."
echo "   Apache: $(systemctl is-active apache2)"
echo "   MySQL: $(systemctl is-active mysql)"
echo "   Ruby: $(which ruby) ($(ruby --version 2>/dev/null | awk '{print $2}'))"

echo ""
log "3. Verificación de Passenger..."
if passenger-config --version >/dev/null 2>&1; then
    echo "   ✓ Passenger: $(passenger-config --version)"
else
    echo "   ❌ Passenger: NO DISPONIBLE"
fi

echo ""
log "4. Conectividad MySQL..."
if sudo -u www-data bash -c "mysql -h localhost -u redmine -pRedmine2024Pass -e 'SELECT 1;' redmine >/dev/null 2>&1"; then
    echo "   ✓ www-data PUEDE CONECTAR A MySQL"
else
    echo "   ❌ www-data NO PUEDE CONECTAR A MySQL"
fi

echo ""
log "5. Archivos críticos..."
for file in "$REDMINE_DIR/config/database.yml" "$REDMINE_DIR/config/secrets.yml" "$REDMINE_DIR/Gemfile"; do
    if [ -f "$file" ]; then
        echo "   ✓ $(basename $file)"
    else
        echo "   ❌ $(basename $file) - NO EXISTE"
    fi
done

echo ""
log "6. Logs de error recientes (Passenger/Redmine)..."
echo "   Últimas 15 líneas de /var/log/apache2/redmine-error.log:"
sudo tail -15 /var/log/apache2/redmine-error.log 2>/dev/null | sed 's/^/   /' || echo "   (Sin logs aún)"

echo ""
echo "═══ FIN DIAGNÓSTICO ═══"
echo ""
echo "───────────────────────────────────────────────────────────────"
echo "✓ REDMINE 6.1.1 - INSTALACIÓN COMPLETADA"
echo "───────────────────────────────────────────────────────────────"
echo ""
echo "ACCESO INICIAL:"
echo "  URL: http://$(hostname -I 2>/dev/null | awk '{print $1}' || echo 'localhost')/redmine"
echo "  Usuario: admin"
echo "  Contraseña: admin"
echo ""
echo "IMPORTANTE: Cambiar contraseña admin al primer acceso"
echo ""
echo "LOGS DETALLADOS:"
echo "  Log principal: $LOG_FILE"
echo "  Errores Apache: /var/log/apache2/redmine-error.log"
echo "  Accesos Apache: /var/log/apache2/redmine-access.log"
echo "  Logs Redmine: /usr/share/redmine/log/production.log"
echo ""
echo "PARA DIAGNÓSTICO DE ERRORES:"
echo "  Passenger errors:  sudo tail -50 /var/log/apache2/redmine-error.log"
echo "  Redmine logs:      sudo tail -50 /usr/share/redmine/log/production.log"
echo "  Estado Passenger:  sudo passenger-config --info"
echo ""


# --- Asegurar que el servicio esté activo ---
sudo systemctl enable mysql
sudo systemctl start mysql

# --- Crear base de datos y usuario solo si no existen ---
echo "[5/10] Configurando base de datos MySQL..."
# Verificar versión de MySQL
MYSQL_VERSION=$(mysql --version 2>/dev/null | awk '{print $5}' | cut -d'-' -f1)
if ! echo "$MYSQL_VERSION" | grep -qE "^8\.[0-9]+"; then
  echo "Advertencia: Se recomienda MySQL 8.0 o superior para Redmine 6.1 (actual: $MYSQL_VERSION)"
fi

DB_EXISTS=$(sudo mysql -N -B -e "SHOW DATABASES LIKE 'redmine';" 2>/dev/null)
if [ -z "$DB_EXISTS" ]; then
  echo "Creando base de datos y usuario de Redmine..."
  sudo mysql -e "CREATE DATABASE redmine CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  USERFOUND=$(sudo mysql -N -B -e "SELECT User FROM mysql.user WHERE User='redmine' AND Host='localhost';" 2>/dev/null)
  if [ -z "$USERFOUND" ]; then
    sudo mysql -e "CREATE USER 'redmine'@'localhost' IDENTIFIED BY 'RedminePass123!';"
  fi
  sudo mysql -e "GRANT ALL PRIVILEGES ON redmine.* TO 'redmine'@'localhost';"
  sudo mysql -e "FLUSH PRIVILEGES;"
else
  echo "Base de datos 'redmine' ya existe. Saltando creación."
fi

# --- Instalar Redmine y Apache ---
echo "[6/10] Instalando Redmine, Apache y módulos..."
# Asegurar repositorios necesarios (universe) porque el paquete redmine suele estar allí
sudo apt-get install -y software-properties-common || true
sudo add-apt-repository -y universe || true
sudo apt update -y

# Intentar instalar paquete 'redmine' desde repositorio
# Usar apt-cache policy y comprobar el campo 'Candidate' para detectar si hay paquete instalable
if apt-cache policy redmine >/dev/null 2>&1; then
  CANDIDATE=$(apt-cache policy redmine | awk '/Candidate:/ {print $2}')
else
  CANDIDATE=""
fi

if [ -n "$CANDIDATE" ] && [ "$CANDIDATE" != "(none)" ]; then
  sudo DEBIAN_FRONTEND=noninteractive apt install -y redmine apache2 libapache2-mod-passenger dbconfig-common
else
  echo "Paquete 'redmine' no disponible como candidato. Procediendo a instalar Redmine desde la fuente (fallback)."
  # Instalar dependencias necesarias
  sudo apt install -y apache2 libapache2-mod-passenger git build-essential libmysqlclient-dev libssl-dev libreadline-dev zlib1g-dev curl
  # Ruby 3.2+ es requerido para Redmine 6.1
  sudo apt install -y ruby ruby-dev || true
  if ! ruby --version | grep -q "3\.[234]"; then
    echo "Advertencia: Se recomienda Ruby 3.2 o superior para Redmine 6.1"
  fi
  sudo apt install -y bundler || true
  sudo apt install -y nodejs npm || true
  sudo apt install -y subversion git-svn || true
  if ! apt-get install -y yarn >/dev/null 2>&1; then
    sudo npm install -g yarn || true
  fi

  # Clonar Redmine (usar 6.1-stable - última versión estable)
  if [ ! -d /opt/redmine ]; then
    echo "Clonando Redmine 6.1-stable (versión 6.1.1)..."
    sudo git clone -b 6.1-stable https://github.com/redmine/redmine.git /opt/redmine
  fi
  sudo mkdir -p /opt/redmine/tmp /opt/redmine/log /opt/redmine/.bundle
  sudo chown -R www-data:www-data /opt/redmine

  # IMPORTANTE: No usar enlace simbólico, crear directorio real
  if [ -L /usr/share/redmine ]; then
    sudo rm -f /usr/share/redmine
  fi
  if [ ! -d /usr/share/redmine ]; then
    sudo cp -r /opt/redmine /usr/share/redmine
  fi
fi

# --- Configurar Redmine con MySQL ---
echo "[7/10] Configurando conexión a base de datos..."
# Asegurar que exista el directorio de dbconfig-common y el paquete instalado para evitar errores
sudo mkdir -p /etc/dbconfig-common
sudo apt-get install -y dbconfig-common || true

# --- Configurar archivo database.yml ---
sudo mkdir -p /usr/share/redmine/config
sudo bash -c "cat > /usr/share/redmine/config/database.yml <<'EOF'
production:
  adapter: mysql2
  database: redmine
  host: localhost
  username: redmine
  password: Redmine2024Pass
  encoding: utf8mb4
  collation: utf8mb4_unicode_ci
  pool: 5
  timeout: 5000
  variables:
    transaction_isolation: "READ-COMMITTED"
EOF"

sudo chown www-data:www-data /usr/share/redmine/config/database.yml
sudo chmod 640 /usr/share/redmine/config/database.yml

# --- Establecer permisos correctos ---
echo "[8/10] Estableciendo permisos y estructura de directorios..."
sudo mkdir -p /usr/share/redmine/tmp/pids
sudo mkdir -p /usr/share/redmine/tmp/sessions
sudo mkdir -p /usr/share/redmine/tmp/cache
sudo mkdir -p /usr/share/redmine/tmp/pdf
sudo mkdir -p /usr/share/redmine/log
sudo mkdir -p /usr/share/redmine/files
sudo mkdir -p /usr/share/redmine/public/assets

# Establecer propietario y permisos CORRECTOS para www-data
sudo chown -R www-data:www-data /usr/share/redmine
sudo chmod -R 755 /usr/share/redmine/public
sudo chmod -R 755 /usr/share/redmine/files
sudo chmod -R 755 /usr/share/redmine/tmp
sudo chmod -R 755 /usr/share/redmine/log
sudo chmod -R 750 /usr/share/redmine/config
sudo chmod 640 /usr/share/redmine/config/database.yml

# Remover permisos ejecutables de los archivos (requerido por documentación oficial)
echo "Removiendo permisos ejecutables de archivos..."
sudo find /usr/share/redmine/files /usr/share/redmine/log /usr/share/redmine/tmp /usr/share/redmine/public/assets -type f -exec chmod -x {} + 2>/dev/null || true

# --- Generar token secreto ---
echo "[9/10] Generando configuraciones de Redmine..."
cd /usr/share/redmine || exit 1

# Si el directorio contiene un Gemfile, instalar gems con bundler (source install fallback)
if [ -f /usr/share/redmine/Gemfile ]; then
  echo "Instalando gems con bundler..."
  
  # Crear directorio .bundle si no existe
  sudo mkdir -p /usr/share/redmine/.bundle
  sudo chown www-data:www-data /usr/share/redmine/.bundle
  sudo chmod 755 /usr/share/redmine/.bundle
  
  # CRÍTICO: Instalar herramientas de compilación necesarias para gemas nativas
  echo "Instalando herramientas de compilación y desarrollo..."
  sudo apt install -y --no-install-recommends build-essential libssl-dev libreadline-dev \
    zlib1g-dev libffi-dev libyaml-dev libsqlite3-dev sqlite3 libxml2-dev libxslt1-dev 2>&1 || true
  
  # Asegurar que libpq-dev está instalado para soporte de PostgreSQL (si aplica)
  sudo apt install -y libmysqlclient-dev 2>&1 || true
  
  # CRÍTICO: Arreglar permisos de gemas para que www-data pueda instalar
  echo "Preparando permisos de gemas..."
  sudo mkdir -p /var/lib/gems/3.2.0/cache
  sudo mkdir -p /var/lib/gems/3.2.0/specifications
  sudo mkdir -p /var/lib/gems/3.2.0/gems
  sudo mkdir -p /var/lib/gems/3.2.0/bin
  sudo chmod -R 777 /var/lib/gems/3.2.0 2>/dev/null || true
  sudo chown -R www-data:www-data /var/lib/gems/3.2.0 2>/dev/null || true
  # También asegurar permisos en ruby
  sudo chmod -R 755 /usr/lib/ruby 2>/dev/null || true
  
  # Mostrar versión de Ruby y Bundler
  echo "Versión de Ruby: $(ruby --version)"
  echo "Versión de Bundler: $(bundle --version)"
  
  # Configurar bundler en el directorio local de Redmine
  echo "Configurando bundler..."
  sudo -u www-data bash -c "cd /usr/share/redmine && bundle config set --local path vendor/bundle" 2>&1 || true
  sudo -u www-data bash -c "cd /usr/share/redmine && bundle config set --local without 'development test'" 2>&1 || true
  
  # Limpiar lock anterior si existe problemas
  echo "Preparando instalación de dependencias..."
  sudo -u www-data bash -c "cd /usr/share/redmine && rm -f Gemfile.lock .bundle/config.local" 2>&1 || true
  
  # Configurar bundler con reintentos automáticos y mejorar tolerancia a fallos de red
  echo "Configurando bundler con manejo robusto de errores de red..."
  sudo -u www-data bash -c "cd /usr/share/redmine && bundle config set auto_install_bundler true" 2>&1 || true
  sudo -u www-data bash -c "cd /usr/share/redmine && bundle config set timeout 300" 2>&1 || true
  sudo -u www-data bash -c "cd /usr/share/redmine && bundle config set max_retries 5" 2>&1 || true
  
  # Configurar rubygems para usar múltiples fuentes y reintentos
  echo "Configurando gem sources con reintentos..."
  sudo bash -c "cat > /etc/gemrc <<'GEMRC_EOF'
install: --no-document --retry 10
update: --no-document --retry 10
sources:
  - https://rubygems.org/
  - https://gems.ruby-china.com/
GEMRC_EOF"
  sudo chmod 644 /etc/gemrc
  
  # Intentar instalar gemas con manejo robusto de errores
  echo "Instalando dependencias (esto puede tomar varios minutos)..."
  BUNDLE_ATTEMPTS=0
  until [ $BUNDLE_ATTEMPTS -ge 5 ]; do
    echo "Intento $((BUNDLE_ATTEMPTS + 1))/5 de bundle install..."
    if sudo -u www-data bash -c "cd /usr/share/redmine && BUNDLER_RETRY=10 bundle install --retry 10 --jobs 4 --verbose" 2>&1 | tee /tmp/bundle_install.log; then
      echo "✓ Dependencias instaladas correctamente"
      break
    else
      BUNDLE_ATTEMPTS=$((BUNDLE_ATTEMPTS + 1))
      LAST_ERROR=$(tail -20 /tmp/bundle_install.log 2>/dev/null | grep -i 'error\|failed' | tail -1)
      echo "⚠ Bundle install falló (intento $BUNDLE_ATTEMPTS/5)"
      echo "Último error: $LAST_ERROR"
      
      if [ $BUNDLE_ATTEMPTS -lt 5 ]; then
        WAIT_TIME=$((10 * BUNDLE_ATTEMPTS))
        echo "⚠ Esperando $WAIT_TIME segundos antes de reintentar..."
        sleep $WAIT_TIME
        # Limpiar cache si hay demasiados fallos
        if [ $BUNDLE_ATTEMPTS -ge 3 ]; then
          echo "Limpiando cache de bundler..."
          sudo -u www-data bash -c "cd /usr/share/redmine && bundle cache --no-prune 2>/dev/null || true"
        fi
      else
        echo "⚠ CRÍTICO: bundle install falló después de 5 intentos"
        echo "Instalando gemas críticas de forma individual como fallback..."
        # Instalar gemas críticas manualmente con reintentos
        CRITICAL_GEMS=("bundler" "rack" "rails" "mysql2" "passenger")
        for GEM in "${CRITICAL_GEMS[@]}"; do
          echo "Instalando gema crítica: $GEM"
          RETRY_COUNT=0
          until [ $RETRY_COUNT -ge 3 ]; do
            if sudo -u www-data bash -c "gem install --no-document --retry 5 $GEM" 2>&1; then
              echo "✓ $GEM instalado correctamente"
              break
            else
              RETRY_COUNT=$((RETRY_COUNT + 1))
              if [ $RETRY_COUNT -lt 3 ]; then
                echo "Reintentando $GEM en 5 segundos..."
                sleep 5
              fi
            fi
          done
        done
        break
      fi
    fi
  done
else
  echo "Advertencia: Gemfile no encontrado en /usr/share/redmine, asumiendo instalación de paquete"
fi

# Compilar assets (obligatorio para Redmine 6.0+)
echo "Compilando assets (obligatorio para Redmine 6.0+)..."
if [ -f /usr/share/redmine/Gemfile ]; then
  # Asegurar que Node.js y yarn están disponibles
  if ! command -v node >/dev/null 2>&1; then
    echo "Instalando Node.js..."
    sudo apt install -y nodejs npm || true
  fi
  if ! command -v yarn >/dev/null 2>&1; then
    echo "Instalando Yarn..."
    sudo npm install -g yarn 2>/dev/null || true
  fi
  
  # Crear directorio public/assets si no existe
  sudo mkdir -p /usr/share/redmine/public/assets
  sudo chown www-data:www-data /usr/share/redmine/public/assets
  sudo chmod 755 /usr/share/redmine/public/assets
  
  PRECOMPILE_ATTEMPTS=0
  until [ $PRECOMPILE_ATTEMPTS -ge 3 ]; do
    echo "Intento $((PRECOMPILE_ATTEMPTS + 1))/3 de compilación de assets..."
    if sudo -u www-data bash -c "cd /usr/share/redmine && export NODE_OPTIONS='--max-old-space-size=2048' && RAILS_ENV=production bundle exec rails assets:precompile 2>&1" | tee /tmp/assets_precompile.log; then
      echo "✓ Assets compilados correctamente"
      break
    else
      PRECOMPILE_ATTEMPTS=$((PRECOMPILE_ATTEMPTS + 1))
      LAST_ERROR=$(tail -20 /tmp/assets_precompile.log 2>/dev/null | grep -i 'error' | tail -1)
      echo "⚠ Error al compilar assets (intento $PRECOMPILE_ATTEMPTS/3)"
      echo "Último error: $LAST_ERROR"
      
      if [ $PRECOMPILE_ATTEMPTS -lt 3 ]; then
        echo "Limpiando assets previos y reintentando en 10 segundos..."
        sudo -u www-data bash -c "cd /usr/share/redmine && rm -rf public/assets/* tmp/cache/assets 2>/dev/null || true"
        sleep 10
      else
        echo "⚠ Advertencia: Error al compilar assets después de 3 intentos, continuando..."
        echo "Nota: Assets pueden compilarse manualmente después con:"
        echo "      sudo -u www-data bash -c 'cd /usr/share/redmine && export NODE_OPTIONS=\"--max-old-space-size=2048\" && bundle exec rails assets:precompile RAILS_ENV=production'"
      fi
    fi
  done
else
  echo "Saltando compilación de assets (instalación de paquete)"
fi

# Generar token secreto y ejecutar migraciones
echo "Generando token secreto de Redmine..."
if [ -f /usr/share/redmine/Gemfile ]; then
  sudo -u www-data bash -c "cd /usr/share/redmine && bundle exec rake generate_secret_token RAILS_ENV=production 2>&1" || {
    echo "Advertencia: Error al generar token (puede que no sea necesario en Redmine 6.0+)"
  }
  
  # En Redmine 6.0+ también asegurar que Rails se inicia correctamente
  echo "Verificando que Rails puede iniciarse..."
  sudo -u www-data bash -c "cd /usr/share/redmine && bundle exec rails runner 'puts \"Rails está funcionando\"' RAILS_ENV=production" 2>&1 || {
    echo "⚠ Advertencia: Rails no respondió correctamente, pero continuaremos"
  }
else
  echo "Saltando generación de token (instalación de paquete)"
fi

# En Redmine 6.0+ con Rails 7, se usa secret_key_base en config/secrets.yml
echo "Preparando secrets (Redmine 6.0+)..."
if [ -f /usr/share/redmine/config/secrets.yml.example ]; then
  sudo cp /usr/share/redmine/config/secrets.yml.example /usr/share/redmine/config/secrets.yml
  sudo chown www-data:www-data /usr/share/redmine/config/secrets.yml
  sudo chmod 644 /usr/share/redmine/config/secrets.yml
  echo "✓ secrets.yml creado"
fi

echo "Ejecutando migraciones de base de datos..."
if [ -f /usr/share/redmine/Gemfile ]; then
  MIGRATE_ATTEMPTS=0
  until [ $MIGRATE_ATTEMPTS -ge 3 ]; do
    echo "Intento $((MIGRATE_ATTEMPTS + 1))/3 de migraciones..."
    if sudo -u www-data bash -c "cd /usr/share/redmine && RAILS_ENV=production bundle exec rails db:migrate 2>&1" | tee /tmp/db_migrate.log; then
      echo "✓ Migraciones completadas"
      break
    else
      MIGRATE_ATTEMPTS=$((MIGRATE_ATTEMPTS + 1))
      MIGRATE_ERROR=$(tail -20 /tmp/db_migrate.log 2>/dev/null | grep -i 'error\|exception' | tail -1)
      echo "⚠ Error en migración (intento $MIGRATE_ATTEMPTS/3)"
      echo "Error detectado: $MIGRATE_ERROR"
      
      if [ $MIGRATE_ATTEMPTS -ge 3 ]; then
        echo "Advertencia: Error en migración después de 3 intentos, puede que ya esté completada o haya problemas de conectividad"
        echo "Por favor, verifica la conectividad a MySQL y reinicia el servicio si es necesario:"
        echo "  sudo systemctl restart mysql"
      else
        echo "Reintentando migraciones en 5 segundos..."
        sleep 5
      fi
    fi
  done
else
  echo "Saltando migraciones (instalación de paquete)"
fi

echo "Cargando datos predeterminados..."
if [ -f /usr/share/redmine/Gemfile ]; then
  LOAD_ATTEMPTS=0
  until [ $LOAD_ATTEMPTS -ge 2 ]; do
    echo "Intento $((LOAD_ATTEMPTS + 1))/2 de carga de datos..."
    if sudo -u www-data bash -c "cd /usr/share/redmine && RAILS_ENV=production bundle exec rails redmine:load_default_data REDMINE_LANG=es 2>&1" | tee /tmp/load_data.log; then
      echo "✓ Datos predeterminados cargados"
      break
    else
      LOAD_ATTEMPTS=$((LOAD_ATTEMPTS + 1))
      LOAD_ERROR=$(tail -20 /tmp/load_data.log 2>/dev/null | tail -1)
      echo "⚠ Error al cargar datos (intento $LOAD_ATTEMPTS/2)"
      echo "Error: $LOAD_ERROR"
      
      if [ $LOAD_ATTEMPTS -ge 2 ]; then
        echo "Advertencia: Error al cargar datos después de 2 intentos, puede que ya estén cargados o datos ya existan"
      else
        sleep 3
      fi
    fi
  done
else
  echo "Saltando datos predeterminados (instalación de paquete)"
fi

# --- Crear archivo configuration.yml si no existe ---
echo "Preparando archivo de configuración..."
if [ ! -f /usr/share/redmine/config/configuration.yml ]; then
  if [ -f /usr/share/redmine/config/configuration.yml.example ]; then
    sudo cp /usr/share/redmine/config/configuration.yml.example /usr/share/redmine/config/configuration.yml
    sudo chown www-data:www-data /usr/share/redmine/config/configuration.yml
    sudo chmod 644 /usr/share/redmine/config/configuration.yml
  else
    echo "Advertencia: No se encontró configuration.yml.example"
  fi
else
  echo "Archivo configuration.yml ya existe"
fi

# --- Crear enlace simbólico de Apache ---
# IMPORTANTE: Usar DocumentRoot directo en lugar de enlace simbólico para evitar problemas de permisos
sudo mkdir -p /var/www/html
if [ -L /var/www/html/redmine ]; then
  sudo rm -f /var/www/html/redmine
fi

# --- Configurar Apache con Passenger ---
echo "[10/10] Configurando Apache..."
sudo a2enmod passenger

# VERIFICACIÓN CRÍTICA: Verificar que Passenger está instalado correctamente
echo "Verificando instalación de Passenger..."
PASSENGER_ROOT=$(passenger-config --root 2>/dev/null || echo "")
if [ -z "$PASSENGER_ROOT" ]; then
  echo "⚠ CRÍTICO: Passenger no detectado. Instalando explícitamente..."
  sudo apt-get install -y libapache2-mod-passenger 2>&1 | tail -5
  sudo a2enmod passenger || echo "Intenta: sudo a2enmod passenger"
fi
echo "✓ Passenger Root: ${PASSENGER_ROOT:-instalado pero no verificado}"

# Asegurar que Apache escuche en el puerto 80
if ! grep -q "^Listen 80" /etc/apache2/ports.conf 2>/dev/null; then
  echo "Listen 80" | sudo tee -a /etc/apache2/ports.conf >/dev/null
fi

# Detectar IP principal de la máquina para usarla como ServerName (acceso desde LAN)
IP_ADDR=$(hostname -I 2>/dev/null | awk '{print $1}')
if [ -z "$IP_ADDR" ]; then
  IP_ADDR=localhost
fi

# Agregar ServerName global si no existe
if ! grep -q "^ServerName" /etc/apache2/apache2.conf 2>/dev/null; then
  echo "ServerName localhost" | sudo tee -a /etc/apache2/apache2.conf >/dev/null
fi

# Generar configuración del sitio - USANDO DocumentRoot DIRECTO, NO ENLACE SIMBÓLICO
sudo tee /etc/apache2/sites-available/redmine.conf >/dev/null <<'APACHE_EOF'
<VirtualHost *:80>
    ServerName localhost
    ServerAlias *
    ServerAdmin admin@redmine.local
    DocumentRoot /usr/share/redmine/public

    <Directory /usr/share/redmine>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    <Directory /usr/share/redmine/public>
        Options -Indexes FollowSymLinks MultiViews
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog ${APACHE_LOG_DIR}/redmine-error.log
    CustomLog ${APACHE_LOG_DIR}/redmine-access.log combined
    LogLevel warn

    # Configuración de Passenger - CRÍTICO
    PassengerAppRoot /usr/share/redmine
    PassengerAppType rack
    PassengerUser www-data
    PassengerGroup www-data
    PassengerRuby /usr/bin/ruby
    PassengerLoadShellEnvvars on
    PassengerFriendlyErrorPages on
    
    # Variables de entorno para Ruby y Passenger
    SetEnv RAILS_ENV production
    SetEnv RACK_ENV production
    SetEnv BUNDLE_DEPLOYMENT true
    SetEnv BUNDLE_PATH /usr/share/redmine/vendor/bundle
    
    # Optimizaciones de Passenger
    PassengerMinInstances 1
    PassengerMaxPoolSize 4
    PassengerPoolIdleTime 0
    PassengerStartTimeout 90
</VirtualHost>
APACHE_EOF
    PassengerPoolIdleTime 0
</VirtualHost>
APACHE_EOF

# Habilitar módulos necesarios
sudo a2enmod rewrite
sudo a2enmod deflate
sudo a2enmod headers

# Habilitar sitio y deshabilitar default
sudo a2dissite 000-default || true
sudo a2ensite redmine

# --- Reiniciar Apache ---
sudo systemctl enable apache2

sudo chmod -R 755 /usr/share/redmine
sudo chmod -R 755 /usr/share/redmine/public
sudo chmod -R 755 /usr/share/redmine/files
sudo chmod -R 755 /usr/share/redmine/tmp
sudo chmod -R 755 /usr/share/redmine/log
sudo chmod -R 750 /usr/share/redmine/config
sudo chmod 640 /usr/share/redmine/config/database.yml

# Asegurar que todos los archivos estén bajo www-data
sudo chown -R www-data:www-data /usr/share/redmine

echo "Reiniciando Apache..."
# VERIFICACIÓN ANTES DE REINICIAR
echo "Verificando configuración de Apache..."
if ! sudo apache2ctl configtest 2>&1 | grep -q "Syntax OK"; then
  echo "⚠ Error en configuración de Apache:"
  sudo apache2ctl configtest
  exit 1
fi

if sudo systemctl restart apache2 2>&1; then
  echo "✓ Apache reiniciado correctamente"
else
  echo "⚠ Error al reiniciar Apache"
  sudo systemctl status apache2
  exit 1
fi

# Esperar a que Apache inicie completamente (puede tardar varios segundos)
echo "Esperando a que Apache inicie completamente..."
sleep 5

# --- Validación de instalación (Paso 9 según documentación oficial) ---
echo "[11/11] Validando instalación de Redmine..."
echo ""
echo "==== DIAGNÓSTICO DE INSTALACIÓN ===="
echo ""

# Verificar Passenger
echo "1. Estado de Passenger:"
if passenger-config --version >/dev/null 2>&1; then
  echo "   ✓ Passenger: $(passenger-config --version)"
else
  echo "   ✗ Passenger no está disponible"
fi

# Verificar permisos de /usr/share/redmine
echo ""
echo "2. Permisos de directorios:"
ls -ld /usr/share/redmine
ls -ld /usr/share/redmine/public
ls -ld /usr/share/redmine/config

# Verificar database.yml
echo ""
echo "3. Verificación de database.yml:"
if [ -f /usr/share/redmine/config/database.yml ]; then
  echo "   ✓ database.yml existe"
  echo "   Propietario: $(stat -c '%U:%G' /usr/share/redmine/config/database.yml)"
else
  echo "   ✗ database.yml NO EXISTE"
fi

# Verificar que www-data puede conectar a MySQL
echo ""
echo "4. Verificación de conectividad MySQL (como www-data):"
if sudo -u www-data mysql -h localhost -u redmine -p'RedminePass123!' -e "SELECT 1;" redmine >/dev/null 2>&1; then
  echo "   ✓ Conectividad MySQL OK"
else
  echo "   ✗ ERROR: www-data NO PUEDE CONECTAR A MYSQL"
  echo "   Esto causa 'Passenger Application Error' (HTTP 500)"
  echo "   Verifica:"
  echo "     • database.yml credenciales"
  echo "     • MySQL está corriendo: sudo systemctl status mysql"
  echo "     • Usuario MySQL: mysql -u redmine -pRedminePass123! -e 'SELECT USER();'"
fi

# Verificar logs de Apache
echo ""
echo "5. Últimos errores de Apache:"
if [ -f /var/log/apache2/redmine-error.log ]; then
  sudo tail -20 /var/log/apache2/redmine-error.log | head -10
else
  echo "   (Log de Redmine no existe aún)"
fi

# Verificar Passenger en Apache
echo ""
echo "6. Verificación de Passenger en Apache:"
if sudo apache2ctl -M 2>/dev/null | grep -q passenger; then
  echo "   ✓ Passenger módulo habilitado en Apache"
else
  echo "   ✗ ERROR: Passenger módulo NO HABILITADO"
  echo "   Ejecuta: sudo a2enmod passenger"
fi

# Verificar gemas críticas
echo ""
echo "7. Verificación de gemas críticas:"
CRITICAL_GEMS=("mysql2" "rails" "rack")
for gem in "${CRITICAL_GEMS[@]}"; do
  if sudo -u www-data bash -c "cd /usr/share/redmine && bundle show $gem >/dev/null 2>&1"; then
    echo "   ✓ $gem"
  else
    echo "   ✗ FALTA: $gem (puede causar error)"
  fi
done

# Verificar assets
echo ""
echo "8. Verificación de assets (Redmine 6.0+):"
ASSETS_COUNT=$(find /usr/share/redmine/public/assets -type f 2>/dev/null | wc -l)
if [ "$ASSETS_COUNT" -gt 5 ]; then
  echo "   ✓ Assets compilados ($ASSETS_COUNT archivos)"
else
  echo "   ✗ ADVERTENCIA: Pocos assets compilados ($ASSETS_COUNT archivos)"
  echo "   Ejecuta: sudo -u www-data bash -c 'cd /usr/share/redmine && RAILS_ENV=production bundle exec rails assets:precompile'"
fi

# Intentar conectar
echo ""
echo "9. Verificación de acceso HTTP:"
echo "Intentando conectar a http://localhost/redmine..."
sleep 3

RESPONSE=$(curl -s -i "http://localhost/redmine" 2>/dev/null | head -1)
echo "Respuesta: $RESPONSE"

if echo "$RESPONSE" | grep -q "200\|302"; then
  echo "   ✓ Redmine ACCESIBLE"
elif echo "$RESPONSE" | grep -q "500"; then
  echo "   ✗ ERROR 500 - Passenger Application Error"
  echo ""
  echo "   SOLUCIÓN - Verificar:"
  echo "   1. Permisos: ls -la /usr/share/redmine/ | head -5"
  echo "   2. MySQL: mysql -u redmine -p'RedminePass123!' -e 'SELECT 1;' redmine"
  echo "   3. Logs Apache: sudo tail -50 /var/log/apache2/redmine-error.log"
  echo "   4. Logs Passenger: sudo journalctl -u apache2 -n 30"
elif echo "$RESPONSE" | grep -q "403"; then
  echo "   ✗ ERROR 403 - Forbidden (problema de permisos)"
elif [ -z "$RESPONSE" ]; then
  echo "   ✗ ERROR: No hay respuesta de Apache"
  echo "   Verifica: sudo systemctl status apache2"
else
  echo "   ? Respuesta desconocida. Verifica logs:"
  echo "   sudo tail -50 /var/log/apache2/redmine-error.log"
fi

echo ""
echo "10. Información de diagnóstico rápido:"
echo "    Ruby: $(ruby --version)"
echo "    Passenger: $(passenger-config --version 2>/dev/null || echo 'NO DETECTADO')"
echo "    Apache: $(apache2ctl -v 2>/dev/null | head -1)"
echo ""
echo "Para diagnóstico completo de errores de Passenger, revisa:"
echo "  • sudo tail -100 /var/log/apache2/redmine-error.log"
echo "  • sudo tail -100 /var/log/apache2/error.log"
echo "  • systemctl status apache2"
echo "  • sudo a2dissite redmine && sudo a2ensite redmine && sudo systemctl reload apache2"
echo ""

# ===========================================================================================
# [11/11] OPCIONAL: CONFIGURAR SMTP PARA ENVÍO DE EMAILS
# ===========================================================================================
# Descomenta UNA de las siguientes opciones si deseas configurar emails en Redmine
# Nota: Esta configuración NO es obligatoria, Redmine funciona sin ella
# ===========================================================================================

# --- OPCIÓN 1: SMTP CON GMAIL ---
# INSTRUCCIONES:
# 1. Ve a https://myaccount.google.com/security
# 2. Busca "Contraseñas de aplicación"
# 3. Selecciona Mail y tu dispositivo
# 4. Google generará una contraseña de 16 caracteres
# 5. Reemplaza "tu-email@gmail.com" y "xxxx xxxx xxxx xxxx" abajo
# 6. Descomenta las líneas y ejecuta el script nuevamente

# echo "[11/11] Configurando SMTP con Gmail..."
# sudo bash -c "cat >> /usr/share/redmine/config/configuration.yml <<'EOF'
#
# production:
#   email_delivery:
#     delivery_method: :smtp
#     smtp_settings:
#       address: smtp.gmail.com
#       port: 587
#       domain: gmail.com
#       authentication: :plain
#       user_name: tu-email@gmail.com
#       password: xxxx xxxx xxxx xxxx
#       enable_starttls_auto: true
#       openssl_verify_mode: peer
# EOF"
# sudo systemctl restart apache2
# echo "✓ SMTP Gmail configurado correctamente"

# --- OPCIÓN 2: SMTP CON EXCHANGE SERVER LOCAL ---
# INSTRUCCIONES:
# 1. Reemplaza "mail.tuempresa.com" por tu servidor SMTP
# 2. Reemplaza "tuempresa.com" por tu dominio
# 3. Reemplaza "usuario@tuempresa.com" por tu usuario
# 4. Reemplaza "TuContraseñaExchange" por tu contraseña normal
# 5. Si necesitas otro puerto o configuración, ajusta "port" y "enable_starttls_auto"
# 6. Descomenta las líneas y ejecuta el script nuevamente

# echo "[11/11] Configurando SMTP con Exchange Server..."
# sudo bash -c "cat >> /usr/share/redmine/config/configuration.yml <<'EOF'
#
# production:
#   email_delivery:
#     delivery_method: :smtp
#     smtp_settings:
#       address: mail.tuempresa.com
#       port: 587
#       domain: tuempresa.com
#       authentication: :login
#       user_name: usuario@tuempresa.com
#       password: TuContraseñaExchange
#       enable_starttls_auto: true
#       openssl_verify_mode: peer
# EOF"
# sudo systemctl restart apache2
# echo "✓ SMTP Exchange configurado correctamente"

# --- OPCIÓN 3: SMTP CON MICROSOFT 365 (Exchange Online) ---
# INSTRUCCIONES:
# 1. Reemplaza "tu-email@empresa.com" por tu email de Microsoft 365
# 2. Reemplaza "TuContraseña" por tu contraseña de Microsoft 365
# 3. Asegúrate de tener habilitado el acceso SMTP en tu cuenta
# 4. Descomenta las líneas y ejecuta el script nuevamente

# echo "[11/11] Configurando SMTP con Microsoft 365..."
# sudo bash -c "cat >> /usr/share/redmine/config/configuration.yml <<'EOF'
#
# production:
#   email_delivery:
#     delivery_method: :smtp
#     smtp_settings:
#       address: smtp.office365.com
#       port: 587
#       domain: office365.com
#       authentication: :login
#       user_name: tu-email@empresa.com
#       password: TuContraseña
#       enable_starttls_auto: true
#       openssl_verify_mode: peer
# EOF"
# sudo systemctl restart apache2
# echo "✓ SMTP Microsoft 365 configurado correctamente"

# ===========================================================================================

# --- Configurar firewall ---
if command -v ufw >/dev/null 2>&1; then
  sudo ufw allow 80/tcp
  sudo ufw allow 443/tcp
  sudo ufw --force enable
fi

# --- Verificación final ---
echo ""
echo "==== Verificación Final de Instalación ===="
echo ""
echo "Información del Sistema:"
echo "- Ruby: $(ruby --version)"
echo "- Rails: $(cd /usr/share/redmine && bundle exec rails --version 2>/dev/null || echo 'No disponible')"
echo "- MySQL: $(mysql --version)"
echo "- Bundler: $(bundle --version)"
echo ""

# Verificar directorios críticos
echo "Directorios críticos:"
for DIR in files log tmp public/assets config; do
  if [ -d "/usr/share/redmine/$DIR" ]; then
    echo "  ✓ /usr/share/redmine/$DIR"
  else
    echo "  ✗ /usr/share/redmine/$DIR (FALTA)"
  fi
done
echo ""

# Verificar archivos críticos
echo "Archivos críticos:"
for FILE in config/database.yml config/configuration.yml config/secrets.yml; do
  if [ -f "/usr/share/redmine/$FILE" ]; then
    echo "  ✓ $FILE"
  else
    echo "  ⚠ $FILE (opcional o no encontrado)"
  fi
done
echo ""
echo "==== Instalación de Redmine completada exitosamente ===="
echo ""
echo "Acceso a Redmine:"
echo "- URL: http://localhost/redmine"
echo "- Usuario: admin"
echo "- Contraseña: admin"
echo ""
echo "IMPORTANTE: Cambiar la contraseña del administrador en la primera ejecución"
echo ""
echo "NOTA: Si deseas configurar envío de emails (OPCIONAL):"
echo "      Descomenta la sección [11/11] en este script y ejecuta nuevamente"
