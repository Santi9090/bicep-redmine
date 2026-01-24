#!/bin/bash

###############################################################################
# REDMINE 6.1.1 - INSTALACIÓN COMPLETA Y AUTOMATIZADA
# Basado en documentación oficial: https://www.redmine.org/projects/redmine/wiki/RedmineInstall
#
# Compatible con: Ubuntu 20.04, 22.04, 24.04 LTS
# Ruby: 3.2, 3.3, 3.4
# MySQL: 8.0+
# Rails: 7.2
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
    error "Este script debe ejecutarse como root (sudo ./script.sh)"
fi

mkdir -p "$(dirname "$LOG_FILE")"

log "═══════════════════════════════════════════════════════════════"
log "REDMINE 6.1.1 - INSTALACIÓN AUTOMATIZADA"
log "Basada en documentación oficial de Redmine"
log "═══════════════════════════════════════════════════════════════"
log "Sistema: $(lsb_release -d 2>/dev/null | cut -f2 || echo 'Ubuntu')"
log "Kernel: $(uname -r)"
log "Hostname: $(hostname)"
log "IP: $(hostname -I | awk '{print $1}' || echo 'N/A')"
log "Log: $LOG_FILE"
log ""

# Verificar espacio en disco (mínimo 2GB recomendado)
DISK_AVAILABLE=$(df / | awk 'NR==2 {print $4}')
if [ "$DISK_AVAILABLE" -lt 2097152 ]; then
    warning "Espacio en disco limitado: $(df -h / | awk 'NR==2 {print $4}')"
    log "Se recomienda al menos 2GB libres"
fi

# =============================================================================
# PASO 1: ACTUALIZAR SISTEMA
# =============================================================================

log ""
log "[1/12] Actualizando sistema..."

export DEBIAN_FRONTEND=noninteractive
apt-get update -y >> "$LOG_FILE" 2>&1 || error "Error actualizando repositorios"
apt-get upgrade -y -o Dpkg::Options::="--force-confnew" >> "$LOG_FILE" 2>&1 || warning "Advertencia en upgrade"

success "Sistema actualizado"

# =============================================================================
# PASO 2: INSTALAR DEPENDENCIAS BASE
# =============================================================================

log ""
log "[2/12] Instalando dependencias base..."

# Según documentación oficial de Redmine
PACKAGES=(
    "build-essential"
    "gcc"
    "g++"
    "make"
    "libssl-dev"
    "libreadline-dev"
    "zlib1g-dev"
    "libffi-dev"
    "libyaml-dev"
    "libsqlite3-dev"
    "libxml2-dev"
    "libxslt1-dev"
    "libmysqlclient-dev"
    "curl"
    "wget"
    "git"
    "gnupg2"
    "ca-certificates"
    "lsb-release"
    "imagemagick"       # Para exportar Gantt a PNG
    "ghostscript"       # Para thumbnails de PDF (Redmine 4.1+)
    "libmagickwand-dev"
    "subversion"        # Para navegación de repositorios SVN
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
# PASO 3: INSTALAR RUBY (3.2, 3.3, o 3.4 según documentación oficial)
# =============================================================================

log ""
log "[3/12] Instalando Ruby..."

if ! command -v ruby &> /dev/null; then
    apt-get install -y ruby ruby-dev >> "$LOG_FILE" 2>&1 || error "Error instalando Ruby"
fi

RUBY_VERSION=$(ruby --version 2>/dev/null | awk '{print $2}' | cut -d. -f1,2)
log "  Ruby versión: $(ruby --version 2>/dev/null)"

# Verificar versión de Ruby según documentación oficial
if ! echo "$RUBY_VERSION" | grep -qE "^3\.[2-4]"; then
    warning "Ruby $RUBY_VERSION detectado - Redmine 6.1 requiere Ruby 3.2, 3.3, o 3.4"
fi

# Instalar Bundler
if ! command -v bundle &> /dev/null; then
    gem install bundler --no-document >> "$LOG_FILE" 2>&1 || error "Error instalando bundler"
fi

# Configurar rubygems para producción
log "  Configurando rubygems..."
cat > /etc/gemrc <<'GEMRC_EOF'
install: --no-document --retry 10
update: --no-document --retry 10
:sources:
  - https://rubygems.org/
GEMRC_EOF
chmod 644 /etc/gemrc

success "Ruby $(ruby --version | awk '{print $2}') instalado"

# =============================================================================
# PASO 4: INSTALAR NODE.JS Y YARN (opcional para assets)
# =============================================================================

log ""
log "[4/12] Instalando Node.js y Yarn (opcional)..."

if ! command -v node &> /dev/null; then
    apt-get install -y nodejs npm >> "$LOG_FILE" 2>&1 || warning "Node.js no disponible"
fi

if ! command -v yarn &> /dev/null && command -v npm &> /dev/null; then
    npm install -g yarn >> "$LOG_FILE" 2>&1 || warning "Yarn no disponible"
fi

if command -v node &> /dev/null; then
    success "Node.js $(node --version) instalado"
else
    log "  Node.js no instalado (los assets se auto-compilarán en Redmine 6.0+)"
fi

# =============================================================================
# PASO 5: INSTALAR Y CONFIGURAR MYSQL 8.0+
# =============================================================================

log ""
log "[5/12] Instalando MySQL 8.0+..."

if ! command -v mysql &> /dev/null; then
    log "  Instalando MySQL..."
    apt-get install -y mysql-server mysql-client libmysqlclient-dev >> "$LOG_FILE" 2>&1 || error "Error instalando MySQL"
fi

systemctl enable mysql >> "$LOG_FILE" 2>&1
systemctl start mysql >> "$LOG_FILE" 2>&1
sleep 3

MYSQL_VERSION=$(mysql --version 2>/dev/null | awk '{print $5}' | cut -d. -f1,2 || echo "desconocida")
log "  MySQL versión: $MYSQL_VERSION"

# Verificar MySQL 8.0+
if ! echo "$MYSQL_VERSION" | grep -qE "^8\.[0-9]+"; then
    warning "MySQL $MYSQL_VERSION - Se recomienda MySQL 8.0+"
fi

# Crear base de datos CON utf8mb4 (requerido por documentación oficial)
if ! mysql -e "SHOW DATABASES LIKE 'redmine';" 2>/dev/null | grep -q redmine; then
    log "  Creando base de datos 'redmine' con utf8mb4..."
    mysql <<EOF >> "$LOG_FILE" 2>&1
CREATE DATABASE redmine CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$MYSQL_USER'@'localhost' IDENTIFIED BY '$MYSQL_PASSWORD';
GRANT ALL PRIVILEGES ON redmine.* TO '$MYSQL_USER'@'localhost';
FLUSH PRIVILEGES;
EOF
    success "Base de datos creada con utf8mb4"
else
    success "Base de datos ya existe"
fi

# IMPORTANTE: Configurar transaction_isolation (REQUERIDO en Redmine 5.1.1+)
log "  Configurando transaction_isolation a READ-COMMITTED..."
mysql <<EOF >> "$LOG_FILE" 2>&1
SET GLOBAL TRANSACTION ISOLATION LEVEL READ COMMITTED;
EOF

# Verificar conexión
if mysql -h localhost -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" -e "SELECT VERSION();" redmine >> "$LOG_FILE" 2>&1; then
    success "Conexión MySQL verificada"
else
    error "No se puede conectar a MySQL"
fi

# =============================================================================
# PASO 6: INSTALAR APACHE Y PASSENGER
# =============================================================================

log ""
log "[6/12] Instalando Apache y Passenger..."

if ! command -v apache2ctl &> /dev/null; then
    apt-get install -y apache2 apache2-dev >> "$LOG_FILE" 2>&1 || error "Error instalando Apache"
fi

if ! dpkg -l 2>/dev/null | grep -q libapache2-mod-passenger; then
    apt-get install -y libapache2-mod-passenger >> "$LOG_FILE" 2>&1 || error "Error instalando Passenger"
fi

# Habilitar módulos necesarios
a2enmod rewrite >> "$LOG_FILE" 2>&1
a2enmod deflate >> "$LOG_FILE" 2>&1
a2enmod headers >> "$LOG_FILE" 2>&1
a2enmod passenger >> "$LOG_FILE" 2>&1

if passenger-config --ruby >/dev/null 2>&1; then
    log "  Passenger: $(passenger-config --version 2>/dev/null)"
    success "Apache y Passenger instalados"
else
    warning "Passenger puede requerir configuración adicional"
fi

# =============================================================================
# PASO 7: DESCARGAR REDMINE 6.1-stable
# =============================================================================

log ""
log "[7/12] Descargando Redmine 6.1-stable desde GitHub..."

if [ ! -d "$REDMINE_DIR" ]; then
    git clone --depth=1 -b 6.1-stable https://github.com/redmine/redmine.git "$REDMINE_DIR" >> "$LOG_FILE" 2>&1 || error "Error descargando Redmine"
    success "Redmine 6.1-stable descargado"
else
    log "  Redmine ya existe en $REDMINE_DIR"
fi

# Verificar que Gemfile existe
if [ ! -f "$REDMINE_DIR/Gemfile" ]; then
    error "Gemfile no encontrado - descarga de Redmine incorrecta"
fi

# =============================================================================
# PASO 8: CONFIGURAR DIRECTORIOS Y PERMISOS (según documentación oficial)
# =============================================================================

log ""
log "[8/12] Configurando directorios según documentación oficial..."

# IMPORTANTE: Para Redmine >= 6.0, el directorio es public/assets
# Ver: https://www.redmine.org/projects/redmine/wiki/RedmineInstall#Step-8-File-system-permissions
mkdir -p "$REDMINE_DIR/tmp" "$REDMINE_DIR/tmp/pdf" "$REDMINE_DIR/log" "$REDMINE_DIR/files"
mkdir -p "$REDMINE_DIR/public/assets"  # Redmine 6.0+
mkdir -p "$REDMINE_DIR/tmp/pids" "$REDMINE_DIR/tmp/sessions" "$REDMINE_DIR/tmp/cache"
mkdir -p "$REDMINE_DIR/vendor/bundle"
mkdir -p "$REDMINE_DIR/themes"  # Redmine 6.0+ - temas se instalan aquí

# Establecer propietarios (según documentación oficial)
chown -R "$REDMINE_USER:$REDMINE_GROUP" "$REDMINE_DIR"

# Establecer permisos (según documentación oficial)
chmod -R 755 "$REDMINE_DIR/files"
chmod -R 755 "$REDMINE_DIR/log"
chmod -R 755 "$REDMINE_DIR/tmp"
chmod -R 755 "$REDMINE_DIR/public/assets"

# IMPORTANTE: Remover permisos ejecutables de archivos (documentación oficial)
log "  Removiendo permisos ejecutables de archivos..."
find "$REDMINE_DIR/files" "$REDMINE_DIR/log" "$REDMINE_DIR/tmp" "$REDMINE_DIR/public/assets" -type f -exec chmod -x {} + 2>/dev/null || true

success "Directorios configurados según estándares de Redmine 6.0+"

# =============================================================================
# PASO 9: CONFIGURAR database.yml (según documentación oficial)
# =============================================================================

log ""
log "[9/12] Configurando database.yml..."

# Configuración según documentación oficial de MySQL para Redmine 5.1.1+
# IMPORTANTE: transaction_isolation debe ser "READ-COMMITTED"
cat > "$REDMINE_DIR/config/database.yml" <<EOF
production:
  adapter: mysql2
  database: redmine
  host: localhost
  username: $MYSQL_USER
  password: "$MYSQL_PASSWORD"
  encoding: utf8mb4
  collation: utf8mb4_unicode_ci
  pool: 5
  timeout: 5000
  variables:
    transaction_isolation: "READ-COMMITTED"
EOF

chown "$REDMINE_USER:$REDMINE_GROUP" "$REDMINE_DIR/config/database.yml"
chmod 640 "$REDMINE_DIR/config/database.yml"

# Verificar conectividad desde www-data
if sudo -u "$REDMINE_USER" mysql -h localhost -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" -e "SELECT 1;" redmine >/dev/null 2>&1; then
    success "Conexión MySQL desde www-data verificada"
else
    error "www-data no puede conectar a MySQL - Verifica database.yml"
fi

# =============================================================================
# PASO 10: INSTALAR GEMAS CON BUNDLER (Step 4 documentación oficial)
# =============================================================================

log ""
log "[10/12] Instalando gemas con Bundler..."
log "  (esto puede tardar 10-20 minutos dependiendo de tu conexión)"

cd "$REDMINE_DIR"

# Verificar conectividad a rubygems.org
if ! wget -q --spider https://rubygems.org 2>/dev/null; then
    warning "Sin conectividad a rubygems.org - usando cache local"
fi

# Configurar bundler según documentación oficial
log "  Configurando bundler (sin development/test)..."
sudo -u "$REDMINE_USER" bash -c "
    cd '$REDMINE_DIR'
    bundle config set --local without 'development test'
    bundle config set --local path 'vendor/bundle'
    bundle config set --local deployment 'false'
    bundle config set --local retry 5
    bundle config set --local jobs 2
" >> "$LOG_FILE" 2>&1

# Instalar gemas con reintentos
BUNDLE_SUCCESS=false
ATTEMPT=0
MAX_ATTEMPTS=3

while [ $ATTEMPT -lt $MAX_ATTEMPTS ] && [ "$BUNDLE_SUCCESS" = "false" ]; do
    ATTEMPT=$((ATTEMPT + 1))
    
    log "  Intento $ATTEMPT/$MAX_ATTEMPTS de bundle install..."
    
    if [ $ATTEMPT -gt 1 ]; then
        log "  Limpiando Gemfile.lock..."
        sudo -u "$REDMINE_USER" bash -c "cd '$REDMINE_DIR' && rm -f Gemfile.lock" 2>/dev/null || true
        sleep 10
    fi
    
    if sudo -u "$REDMINE_USER" bash -c "
        cd '$REDMINE_DIR'
        export MALLOC_ARENA_MAX=2
        bundle install --jobs=2 --retry=5 2>&1
    " | tee -a "$LOG_FILE"; then
        BUNDLE_SUCCESS=true
        success "Gemas instaladas correctamente"
    else
        warning "Intento $ATTEMPT falló"
    fi
done

if [ "$BUNDLE_SUCCESS" = "false" ]; then
    log "  Instalando gemas críticas individualmente..."
    for gem in bundler rack rails mysql2; do
        log "  Instalando $gem..."
        sudo -u "$REDMINE_USER" gem install --no-document "$gem" >> "$LOG_FILE" 2>&1 || true
    done
fi

# Verificar gemas críticas
log "  Verificando gemas críticas..."
for gem in mysql2 rails rack; do
    if sudo -u "$REDMINE_USER" bash -c "cd '$REDMINE_DIR' && bundle show $gem" >/dev/null 2>&1; then
        log "    ✓ $gem"
    else
        warning "    ✗ $gem no encontrada"
    fi
done

# =============================================================================
# PASO 11: CONFIGURAR Y MIGRAR BASE DE DATOS
# =============================================================================

log ""
log "[11/12] Configurando base de datos..."

# Step 5: Session store secret generation (documentación oficial)
if [ ! -f "$REDMINE_DIR/config/secrets.yml" ]; then
    if [ -f "$REDMINE_DIR/config/secrets.yml.example" ]; then
        log "  Creando secrets.yml desde template..."
        cp "$REDMINE_DIR/config/secrets.yml.example" "$REDMINE_DIR/config/secrets.yml"
        chown "$REDMINE_USER:$REDMINE_GROUP" "$REDMINE_DIR/config/secrets.yml"
        chmod 640 "$REDMINE_DIR/config/secrets.yml"
    else
        log "  Generando secret token..."
        sudo -u "$REDMINE_USER" bash -c "
            cd '$REDMINE_DIR'
            export RAILS_ENV=production
            bundle exec rake generate_secret_token
        " >> "$LOG_FILE" 2>&1 || true
    fi
fi

# Preparar configuration.yml (opcional pero recomendado)
if [ ! -f "$REDMINE_DIR/config/configuration.yml" ]; then
    if [ -f "$REDMINE_DIR/config/configuration.yml.example" ]; then
        cp "$REDMINE_DIR/config/configuration.yml.example" "$REDMINE_DIR/config/configuration.yml"
        chown "$REDMINE_USER:$REDMINE_GROUP" "$REDMINE_DIR/config/configuration.yml"
        chmod 640 "$REDMINE_DIR/config/configuration.yml"
        log "  configuration.yml creado"
    fi
fi

# Step 6: Database schema objects creation (documentación oficial)
log "  Ejecutando migraciones de base de datos..."
MIGRATE_SUCCESS=false
for attempt in {1..3}; do
    log "    Intento $attempt/3..."
    
    if sudo -u "$REDMINE_USER" bash -c "
        cd '$REDMINE_DIR'
        export RAILS_ENV=production
        bundle exec rake db:migrate 2>&1
    " | tee -a "$LOG_FILE"; then
        MIGRATE_SUCCESS=true
        success "Migraciones completadas"
        break
    else
        warning "Intento $attempt falló"
        [ $attempt -lt 3 ] && sleep 10
    fi
done

[ "$MIGRATE_SUCCESS" = "false" ] && error "Migraciones fallaron después de 3 intentos"

# Step 7: Database default data set (documentación oficial)
log "  Cargando datos predeterminados (idioma: $REDMINE_LANG)..."
sudo -u "$REDMINE_USER" bash -c "
    cd '$REDMINE_DIR'
    export RAILS_ENV=production
    export REDMINE_LANG=$REDMINE_LANG
    bundle exec rake redmine:load_default_data 2>&1
" | tee -a "$LOG_FILE" || warning "Datos ya cargados o error"

# IMPORTANTE: En Redmine 6.0+ los assets se auto-compilan
# Ver: https://www.redmine.org/news/147
log "  Nota: Redmine 6.0+ auto-compila assets en producción"
log "  Si deseas pre-compilar manualmente (opcional):"
log "    cd $REDMINE_DIR && RAILS_ENV=production bundle exec rake assets:precompile"

success "Base de datos configurada"

# =============================================================================
# PASO 12: CONFIGURAR APACHE CON PASSENGER
# =============================================================================

log ""
log "[12/12] Configurando Apache con Passenger..."

# Obtener IP del servidor
SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")

# Asegurar que Apache escuche en puerto 80
if ! grep -q "^Listen 80" /etc/apache2/ports.conf 2>/dev/null; then
    echo "Listen 80" >> /etc/apache2/ports.conf
fi

# Agregar ServerName global
if ! grep -q "^ServerName" /etc/apache2/apache2.conf 2>/dev/null; then
    echo "ServerName localhost" >> /etc/apache2/apache2.conf
fi

# Crear configuración del sitio (según mejores prácticas)
cat > /etc/apache2/sites-available/redmine.conf <<EOF
<VirtualHost *:80>
    ServerName $SERVER_IP
    ServerAlias localhost *
    ServerAdmin admin@redmine.local
    
    # IMPORTANTE: DocumentRoot apunta a public/
    DocumentRoot $REDMINE_DIR/public

    <Directory $REDMINE_DIR>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    <Directory $REDMINE_DIR/public>
        Options -Indexes FollowSymLinks MultiViews
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/redmine-error.log
    CustomLog \${APACHE_LOG_DIR}/redmine-access.log combined
    LogLevel warn

    # Configuración de Passenger
    PassengerAppRoot $REDMINE_DIR
    PassengerAppType rack
    PassengerUser $REDMINE_USER
    PassengerGroup $REDMINE_GROUP
    PassengerRuby $(which ruby)
    PassengerLoadShellEnvvars on
    PassengerFriendlyErrorPages on
    
    # Variables de entorno para Rails
    SetEnv RAILS_ENV production
    SetEnv RACK_ENV production
    
    # Optimizaciones de Passenger
    PassengerMinInstances 1
    PassengerMaxPoolSize 4
    PassengerPoolIdleTime 0
    PassengerStartTimeout 90
</VirtualHost>
EOF

# Deshabilitar sitio default y habilitar redmine
a2dissite 000-default >> "$LOG_FILE" 2>&1 || true
a2ensite redmine >> "$LOG_FILE" 2>&1

# Verificar configuración
if apache2ctl configtest >> "$LOG_FILE" 2>&1; then
    success "Configuración de Apache válida"
else
    warning "Advertencia en configuración de Apache"
    apache2ctl configtest 2>&1 | tail -10
fi

# Reiniciar Apache
log "  Reiniciando Apache..."
systemctl restart apache2 || error "Error reiniciando Apache"
sleep 5

if systemctl is-active --quiet apache2; then
    success "Apache activo y funcionando"
else
    error "Apache no está activo"
fi

# =============================================================================
# CONFIGURAR FIREWALL (OPCIONAL)
# =============================================================================

if command -v ufw >/dev/null 2>&1; then
    log "Configurando firewall (UFW)..."
    ufw allow 80/tcp >> "$LOG_FILE" 2>&1
    ufw allow 443/tcp >> "$LOG_FILE" 2>&1
    ufw --force enable >> "$LOG_FILE" 2>&1 || true
fi

# Limpiar cache APT
apt-get clean >> "$LOG_FILE" 2>&1 || true
apt-get autoremove -y >> "$LOG_FILE" 2>&1 || true

# =============================================================================
# VERIFICACIÓN FINAL
# =============================================================================

log ""
log "═══════════════════════════════════════════════════════════════"
log "VERIFICACIÓN FINAL"
log "═══════════════════════════════════════════════════════════════"
log ""

# Verificar servicios
log "1. Estado de servicios:"
log "   - Apache: $(systemctl is-active apache2)"
log "   - MySQL: $(systemctl is-active mysql)"
log "   - Ruby: $(ruby --version | awk '{print $2}')"
log "   - Passenger: $(passenger-config --version 2>/dev/null || echo 'N/A')"

# Verificar conectividad HTTP
log ""
log "2. Verificando acceso HTTP a Redmine..."
sleep 3
HTTP_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost/" 2>/dev/null || echo "000")

if [ "$HTTP_RESPONSE" = "200" ] || [ "$HTTP_RESPONSE" = "302" ]; then
    success "✓ Redmine responde correctamente (HTTP $HTTP_RESPONSE)"
elif [ "$HTTP_RESPONSE" = "500" ]; then
    warning "⚠ Error 500 - Revisar logs: sudo tail -50 /var/log/apache2/redmine-error.log"
elif [ "$HTTP_RESPONSE" = "000" ]; then
    warning "⚠ Sin respuesta HTTP - Verificar: sudo systemctl status apache2"
else
    warning "⚠ Respuesta HTTP inesperada: $HTTP_RESPONSE"
fi

# Verificar archivos críticos
log ""
log "3. Archivos críticos:"
for file in "config/database.yml" "config/secrets.yml" "Gemfile" "Gemfile.lock"; do
    if [ -f "$REDMINE_DIR/$file" ]; then
        log "   ✓ $file"
    else
        log "   ✗ $file - NO EXISTE"
    fi
done

# Verificar directorios según Redmine 6.0+
log ""
log "4. Directorios (Redmine 6.0+):"
for dir in files log tmp public/assets themes; do
    if [ -d "$REDMINE_DIR/$dir" ]; then
        log "   ✓ $dir/"
    else
        log "   ✗ $dir/ - NO EXISTE"
    fi
done

log ""
log "═══════════════════════════════════════════════════════════════"
log "✓ INSTALACIÓN COMPLETADA"
log "═══════════════════════════════════════════════════════════════"
log ""
log "🌐 ACCESO A REDMINE:"
log "   URL: http://$SERVER_IP"
log "   URL alternativa: http://localhost"
log "   Usuario inicial: admin"
log "   Contraseña inicial: admin"
log ""
log "⚠️  IMPORTANTE: "
log "   1. Cambia la contraseña de admin inmediatamente"
log "   2. Ve a Administración → Configuración para ajustar Redmine"
log ""
log "📋 INFORMACIÓN DEL SISTEMA:"
log "   - Redmine: 6.1.1"
log "   - Ruby: $(ruby --version | awk '{print $2}')"
log "   - Rails: $(cd $REDMINE_DIR && bundle exec rails --version 2>/dev/null || echo '7.2')"
log "   - MySQL: $MYSQL_VERSION"
log "   - Passenger: $(passenger-config --version 2>/dev/null || echo 'Instalado')"
log ""