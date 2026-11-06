#!/usr/bin/env bash
# ==============================================================================
# Script: teardown_users.sh
# Finalidade: Desprovisionamento e remoção limpa dos usuários e grupos criados
#             pelo laboratório a partir do arquivo CSV.
# Autor: Cesar Lana (Laboratório AWS)
# ==============================================================================

set -euo pipefail

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO] $(date '+%Y-%m-%d %H:%M:%S')${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS] $(date '+%Y-%m-%d %H:%M:%S')${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN] $(date '+%Y-%m-%d %H:%M:%S')${NC} $1"; }
log_error() { echo -e "${RED}[ERROR] $(date '+%Y-%m-%d %H:%M:%S')${NC} $1" >&2; }

CSV_FILE=""
DELETE_GROUPS=false

show_help() {
    cat << EOF
Uso: $0 --csv <ARQUIVO_CSV> [OPÇÕES]

Opções:
  -c, --csv ARQUIVO    Caminho para o arquivo CSV de usuários a remover (Obrigatório)
  --delete-groups      Remove também os grupos IAM especificados no CSV
  -h, --help           Exibe esta mensagem de ajuda
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--csv) CSV_FILE="$2"; shift 2 ;;
        --delete-groups) DELETE_GROUPS=true; shift ;;
        -h|--help) show_help; exit 0 ;;
        *) log_error "Opção desconhecida: $1"; show_help; exit 1 ;;
    esac
done

if [[ -z "$CSV_FILE" || ! -f "$CSV_FILE" ]]; then
    log_error "Arquivo CSV inválido ou não informado."
    show_help
    exit 1
fi

log_warn "Iniciando processo de remoção e limpeza (Teardown) com base em: $CSV_FILE"

GROUPS_TO_CHECK=()

while IFS=',' read -r USERNAME GROUP TEMP_PASSWORD || [[ -n "$USERNAME" ]]; do
    USERNAME=$(echo "$USERNAME" | tr -d '\r' | xargs)
    GROUP=$(echo "$GROUP" | tr -d '\r' | xargs)

    if [[ -z "$USERNAME" || "$USERNAME" =~ ^# || "${USERNAME,,}" == "username" ]]; then
        continue
    fi

    if [[ -n "$GROUP" ]]; then
        GROUPS_TO_CHECK+=("$GROUP")
    fi

    if ! aws iam get-user --user-name "$USERNAME" &> /dev/null; then
        log_info "Usuário '${USERNAME}' não existe no IAM. Pulando."
        continue
    fi

    log_info "Removendo usuário '${USERNAME}'..."

    # 1. Remover de todos os grupos vinculados
    USER_GROUPS=$(aws iam list-groups-for-user --user-name "$USERNAME" --query "Groups[*].GroupName" --output text 2>/dev/null || echo "")
    for g in $USER_GROUPS; do
        aws iam remove-user-from-group --user-name "$USERNAME" --group-name "$g" 2>/dev/null || true
        log_info "  Removido do grupo: $g"
    done

    # 2. Deletar login profile se existir
    aws iam delete-login-profile --user-name "$USERNAME" 2>/dev/null || true

    # 3. Remover chaves de acesso caso tenham sido geradas
    ACCESS_KEYS=$(aws iam list-access-keys --user-name "$USERNAME" --query "AccessKeyMetadata[*].AccessKeyId" --output text 2>/dev/null || echo "")
    for k in $ACCESS_KEYS; do
        aws iam delete-access-key --user-name "$USERNAME" --access-key-id "$k" 2>/dev/null || true
        log_info "  Removida access key: $k"
    done

    # 4. Deletar usuário IAM
    aws iam delete-user --user-name "$USERNAME"
    log_success "Usuário '${USERNAME}' removido com sucesso."

done < "$CSV_FILE"

# Opcional: remover grupos esvaziados
if [[ "$DELETE_GROUPS" == true ]]; then
    # Remover duplicatas da lista de grupos
    UNIQUE_GROUPS=($(printf "%s\n" "${GROUPS_TO_CHECK[@]}" | sort -u))
    for grp in "${UNIQUE_GROUPS[@]}"; do
        log_info "Tentando remover grupo: $grp..."
        aws iam delete-group --group-name "$grp" 2>/dev/null || log_warn "Grupo '$grp' não pôde ser excluído (pode conter outros usuários ou políticas anexadas)."
    done
fi

log_success "Teardown de usuários concluído com sucesso!"
