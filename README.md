# Validator-Tools

## Настройка автоголосования валидатора

<h3> Создайте кошелёк с именем  votewallet  которому вы делегируете полномочия</h3>

>В моих примерах я буду использовать сеть sommelier
>и кошельки с названиями wallet и votewallet (будет удобно, если ваши кошельки будути иметь такие же названия)


<h4>Кошелёк на котором вы будете хранить только минимум необходимый для транзакций связаных с голосованием:</h4>

```bash
sommelier keys add votewallet --keyring-backend test
```

>Ключ хранится в открытом виде в ~/.YOUR_NODE/keyring-test. Например: ~/.sommelier/keyring-test </br>
>CLI не будет спрашивать пароль вообще.

---

<h3> Выдайте разрешение для голосования кошельку votewallet:</h3>

```
sommelier tx authz grant $(sommelier keys show votewallet -a) generic --msg-type /cosmos.gov.v1.MsgVote \
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
