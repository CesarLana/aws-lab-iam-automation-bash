#!/usr/bin/env bash
# ==============================================================================
# Script: provision_users.sh
# Finalidade: Provisionamento automatizado em massa de usuários no AWS IAM
#             a partir de arquivo CSV, com tags, vinculação a grupos de menor
#             privilégio e obrigatoriedade de troca de senha no primeiro acesso.
# Autor: Cesar Lana (Laboratório AWS)
# ==============================================================================

set -euo pipefail

# Cores para formatação de saída
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO] $(date '+%Y-%m-%d %H:%M:%S')${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS] $(date '+%Y-%m-%d %H:%M:%S')${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN] $(date '+%Y-%m-%d %H:%M:%S')${NC} $1"; }
log_error() { echo -e "${RED}[ERROR] $(date '+%Y-%m-%d %H:%M:%S')${NC} $1" >&2; }

CSV_FILE=""
DRY_RUN=false
CREATE_GROUPS=true

show_help() {
    cat << EOF
Uso: $0 --csv <ARQUIVO_CSV> [OPÇÕES]

Opções:
  -c, --csv ARQUIVO     Caminho para o arquivo CSV de entrada (Obrigatório)
  -d, --dry-run         Executa simulação sem realizar mutações reais no IAM
  --no-create-groups    Não cria grupos automaticamente se eles não existirem
  -h, --help            Exibe esta mensagem de ajuda

Estrutura esperada do CSV:
  username,group,temporary_password
  joao.silva,SupportUsers,Temp@2026!Key1
EOF
}

# Parse de argumentos
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--csv) CSV_FILE="$2"; shift 2 ;;
        -d|--dry-run) DRY_RUN=true; shift ;;
        --no-create-groups) CREATE_GROUPS=false; shift ;;
        -h|--help) show_help; exit 0 ;;
        *) log_error "Opção inválida: $1"; show_help; exit 1 ;;
    esac
done

if [[ -z "$CSV_FILE" ]]; then
    log_error "O parâmetro --csv é obrigatório."
    show_help
    exit 1
fi

if [[ ! -f "$CSV_FILE" ]]; then
    log_error "Arquivo CSV não encontrado: '$CSV_FILE'"
    exit 1
fi

# Validação do AWS CLI
if ! command -v aws &> /dev/null; then
    log_error "AWS CLI não encontrado. Instale o AWS CLI v2 antes de executar este script."
    exit 1
fi

# Validação de credenciais ativas na AWS
log_info "Validando credenciais da AWS..."
if ! CALLER_IDENTITY=$(aws sts get-caller-identity --output json 2>/dev/null); then
    log_error "Credenciais AWS inválidas ou não configuradas. Execute 'aws configure' ou exporte as credenciais."
    exit 1
fi

ACCOUNT_ID=$(echo "$CALLER_IDENTITY" | grep -o '"Account": "[^"]*' | cut -d'"' -f4)
ARN=$(echo "$CALLER_IDENTITY" | grep -o '"Arn": "[^"]*' | cut -d'"' -f4)
log_success "Autenticado na Conta AWS: ${ACCOUNT_ID} (${ARN})"

if [[ "$DRY_RUN" == true ]]; then
    log_warn "=== MODO DE SIMULAÇÃO (DRY-RUN) ATIVADO. NENHUMA ALTERAÇÃO SERÁ REALIZADA NO IAM ==="
fi

# Contadores de métricas
COUNT_TOTAL=0
COUNT_CREATED=0
COUNT_EXISTING=0
COUNT_ERRORS=0

log_info "Iniciando processamento do arquivo: ${CSV_FILE}"

# Leitura do CSV linha por linha
# Processa removendo carriage returns (\r) de arquivos Windows
while IFS=',' read -r USERNAME GROUP TEMP_PASSWORD || [[ -n "$USERNAME" ]]; do
    # Limpa espaços e carriage returns
    USERNAME=$(echo "$USERNAME" | tr -d '\r' | xargs)
    GROUP=$(echo "$GROUP" | tr -d '\r' | xargs)
    TEMP_PASSWORD=$(echo "$TEMP_PASSWORD" | tr -d '\r' | xargs)

    # Ignora linhas vazias ou comentários
    if [[ -z "$USERNAME" || "$USERNAME" =~ ^# ]]; then
        continue
    fi

    # Ignora cabeçalho
    if [[ "${USERNAME,,}" == "username" ]]; then
        continue
    fi

    COUNT_TOTAL=$((COUNT_TOTAL + 1))
    echo -e "${CYAN}------------------------------------------------------------${NC}"
    log_info "Processando usuário #$COUNT_TOTAL: [${USERNAME}] | Grupo: [${GROUP}]"

    # Validação do nome de usuário segundo padrões do IAM
    if ! [[ "$USERNAME" =~ ^[a-zA-Z0-9+=,.@_-]+$ ]]; then
        log_error "Nome de usuário inválido segundo as regras do AWS IAM: '${USERNAME}'"
        COUNT_ERRORS=$((COUNT_ERRORS + 1))
        continue
    fi

    # Validação da senha temporária (comprimento mínimo 8 caracteres)
    if [[ ${#TEMP_PASSWORD} -lt 8 ]]; then
        log_error "A senha temporária para '${USERNAME}' deve ter no mínimo 8 caracteres."
        COUNT_ERRORS=$((COUNT_ERRORS + 1))
        continue
    fi

    # 1. Validação/Criação do Grupo IAM
    if [[ -n "$GROUP" ]]; then
        if ! aws iam get-group --group-name "$GROUP" &> /dev/null; then
            if [[ "$CREATE_GROUPS" == true ]]; then
                log_warn "Grupo IAM '${GROUP}' não existe."
                if [[ "$DRY_RUN" == false ]]; then
                    log_info "Criando grupo IAM '${GROUP}'..."
                    aws iam create-group --group-name "$GROUP" > /dev/null
                    log_success "Grupo '${GROUP}' criado com sucesso."
                else
                    log_info "[DRY-RUN] Criaria grupo IAM: ${GROUP}"
                fi
            else
                log_error "Grupo '${GROUP}' não existe e --no-create-groups foi especificado. Abortando usuário."
                COUNT_ERRORS=$((COUNT_ERRORS + 1))
                continue
            fi
        fi
    fi

    # 2. Verificação se o usuário já existe
    USER_EXISTS=false
    if aws iam get-user --user-name "$USERNAME" &> /dev/null; then
        USER_EXISTS=true
        log_warn "Usuário IAM '${USERNAME}' já existe na conta."
        COUNT_EXISTING=$((COUNT_EXISTING + 1))
    fi

    # 3. Criação do Usuário IAM caso não exista
    if [[ "$USER_EXISTS" == false ]]; then
        if [[ "$DRY_RUN" == false ]]; then
            log_info "Criando usuário IAM '${USERNAME}' com tags de governança..."
            aws iam create-user \
                --user-name "$USERNAME" \
                --tags \
                    Key=CreatedBy,Value=IAM-Automation \
                    Key=Environment=Lab \
                    Key=ProvisionDate="$(date +%Y-%m-%d)" > /dev/null
            log_success "Usuário '${USERNAME}' criado com sucesso."

            # Criação do perfil de login web com troca de senha obrigatória
            log_info "Configurando login web com flag --password-reset-required..."
            aws iam create-login-profile \
                --user-name "$USERNAME" \
                --password "$TEMP_PASSWORD" \
                --password-reset-required > /dev/null
            log_success "Perfil de acesso criado: Troca obrigatória no primeiro login ativada."
            COUNT_CREATED=$((COUNT_CREATED + 1))
        else
            log_info "[DRY-RUN] Criaria usuário: ${USERNAME}"
            log_info "[DRY-RUN] Ativaria login web com --password-reset-required"
            COUNT_CREATED=$((COUNT_CREATED + 1))
        fi
    fi

    # 4. Associação ao Grupo IAM
    if [[ -n "$GROUP" ]]; then
        if [[ "$DRY_RUN" == false ]]; then
            log_info "Associando usuário '${USERNAME}' ao grupo '${GROUP}'..."
            aws iam add-user-to-group \
                --user-name "$USERNAME" \
                --group-name "$GROUP" > /dev/null
            log_success "Usuário '${USERNAME}' adicionado ao grupo '${GROUP}'."
        else
            log_info "[DRY-RUN] Associaria '${USERNAME}' ao grupo '${GROUP}'"
        fi
    fi

done < "$CSV_FILE"

echo -e "${CYAN}============================================================${NC}"
log_info "Resumo do Provisionamento IAM:"
echo "  Total processados : $COUNT_TOTAL"
echo "  Criados com êxito : $COUNT_CREATED"
echo "  Já existentes     : $COUNT_EXISTING"
echo "  Erros/Falhas      : $COUNT_ERRORS"
echo -e "${CYAN}============================================================${NC}"

if [[ $COUNT_ERRORS -gt 0 ]]; then
    log_warn "A execução finalizou com $COUNT_ERRORS erro(s)."
    exit 1
else
    log_success "Provisionamento concluído com êxito total!"
    exit 0
fi
