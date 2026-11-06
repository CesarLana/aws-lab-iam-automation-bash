#!/usr/bin/env bash
# ==============================================================================
# Script: provision_users.sh
# Finalidade: Provisionar usuários em massa no AWS IAM a partir de um arquivo CSV
# Prática da formação AWS re/Start (Escola da Nuvem)
# ==============================================================================

ARQUIVO_CSV="usuarios.csv"

# 1. Verifica se o arquivo CSV existe
if [ ! -f "$ARQUIVO_CSV" ]; then
    echo "Erro: Arquivo $ARQUIVO_CSV nao encontrado!"
    echo "Crie o arquivo com o formato: usuario,grupo,senha_temporaria"
    exit 1
fi

echo "Iniciando provisionamento de usuarios no AWS IAM..."
echo "----------------------------------------------------"

# 2. Le o arquivo CSV linha por linha (ignorando a primeira linha de cabecalho)
tail -n +2 "$ARQUIVO_CSV" | while IFS="," read -r usuario grupo senha; do
    # Remove eventuais espacos em branco ou quebras de linha
    usuario=$(echo "$usuario" | xargs)
    grupo=$(echo "$grupo" | xargs)
    senha=$(echo "$senha" | xargs)

    if [ -z "$usuario" ]; then
        continue
    fi

    echo ">> Processando usuario: $usuario (Grupo: $grupo)"

    # Cria o usuario no IAM
    aws iam create-user --user-name "$usuario"

    # Cria o perfil de login no console com senha temporaria e obriga a troca no 1º acesso
    aws iam create-login-profile \
        --user-name "$usuario" \
        --password "$senha" \
        --password-reset-required

    # Adiciona o usuario ao grupo com as permissoes do setor dele
    aws iam add-user-to-group \
        --user-name "$usuario" \
        --group-name "$grupo"

    echo "   [OK] Usuario $usuario criado e vinculado ao grupo $grupo."
done

echo "----------------------------------------------------"
echo "Todos os usuarios foram provisionados com sucesso!"
