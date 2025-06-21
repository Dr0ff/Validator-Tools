# Настройка автоголосования валидатора

## Подготовка кошелька для голосования
<h3> Создайте кошелёк с именем  votewallet  которому вы делегируете полномочия</h3>

>В моих примерах я буду использовать сеть sommelier
>и кошельки с названиями wallet и votewallet (будет удобно, если ваши кошельки будути иметь такие же названия).</br>
>А также используйте параметры вашей сети (DAEMON, chain-id, denom, gas...)


<h4>Кошелёк на котором вы будете хранить только минимум необходимый для транзакций связаных с голосованием:</h4>

```bash
sommelier keys add votewallet --keyring-backend test
```

>Ключ хранится в открытом виде в ~/.YOUR_NODE/keyring-test. Например: ~/.sommelier/keyring-test </br>
>CLI не будет спрашивать пароль вообще.

---

<h3> Выдайте разрешение для голосования кошельку votewallet:</h3>

```
sommelier tx authz grant $(sommelier keys show votewallet --keyring-backend test -a) generic --msg-type /cosmos.gov.v1.MsgVote \
--from wallet \
--expiration 1812188258 \
--gas 250000 \
--gas-prices 0.025usomm \
--gas-adjustment 1.5 \
--chain-id sommelier-3
```
Проверка авторизации:

```
sommelier q authz grants $(sommelier keys show wallet -a) $(sommelier keys show votewallet -a)
```
Отзыв авторизаци:

```
sommelier tx authz revoke $(sommelier keys show votewallet -a) "/cosmos.gov.v1.MsgVote" --from wallet --gas 250000 --gas-prices 0.025usomm --gas-adjustment 1.5 --chain-id sommelier-3
```

---

<h3> Теперь можно перекинуть немного токенов на этот кошелёк...</h3>

---

## Настройка автоголосования
<h3>Скачайте скрипт на ваш сервер в директорию в которой установлена нода</h3>

 ❗️ Переходим в дирректорию в которой установлена нода. У меня это *.sommelier* </br>
     `cd .sommelier/`

```
wget https://raw.githubusercontent.com/Dr0ff/Validator-Tools/refs/heads/main/autovoting.sh
```
---

<h3>Редактируем скрипт</h3>

>Необходимо прописать несколько параметров которые соответствуют вашей конфигурации

```
nano autovoting.sh
```

 *Описание параметров которые необходимо заменить на ваши:*
```
CLI_NAME="DAEMON"                 # Название вашего DAEMON (junod, lavad...)
USE_LOCAL_NODE=true               # Если ваша нода синхронизирована, то этот параметр должен быть true
                                  # Если нет, то установите false и используйте публичную ноду
NODE_URL="https://rpc.node:port"  # Здесь нужно указать рабочую PRC если у вас нет ноды или она не синхронизирована
CHAIN_ID="YOUR_NETWORK_CHAIN-ID"  # Укажите Chain-Id вашей сети
VOTERWALLET="votewallet"          # Укажите название или адрес кошелька который будет использоваться для голосования
FEES="5000utoken"                 # Укажите fee и деном для вашей сети (e.g., usomm, ujuno)
```
<h3>Запускаем скприт:</h3>

```
bash autovoting.sh
```
