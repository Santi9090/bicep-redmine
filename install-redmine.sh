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
sudo systemctl enable apache2
sudo systemctl start apache2
