# FunnyHub — key page

Static ad-reward key page for the **FunnyHub** KeyHub system, ready for GitHub
Pages. Users open it, complete 2 ad tasks, get a 24h key, then paste it into the
in-game GUI.

```
funnyhub-web/
  index.html      the key page (GitHub Pages entry)
  config.js       <- set your API URL here
  funnyhub.lua    the loader users execute (loadstring from this repo)
  .nojekyll
```

## 1. Point the page at your API

Edit `config.js`:

```js
window.KEYHUB_API = "https://your-keyhub-domain";
window.KEYHUB_TITLE = "FunnyHub — Get your key";
```

Leave it `""` only if the KeyHub server itself is serving this page.

## 2. Publish on GitHub Pages

```powershell
git init -b main
git add -A
git commit -m "FunnyHub key page"
git remote add origin https://github.com/YOURUSER/funnyhub-web.git
git push -u origin main
```

Then **Settings → Pages → Source: Deploy from a branch → main / (root)**.

Your page: `https://YOURUSER.github.io/funnyhub-web/`

## 3. The loader users run

Edit `API_URL` (and keep `SCRIPT_ID`) inside `funnyhub.lua`, then tell users:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/YOURUSER/funnyhub-web/main/funnyhub.lua"))()
```

The loader:
- auto-redeems a saved key (remembered per HWID),
- otherwise shows **GET KEY** (copies the key page link) and **REDEEM KEY**.

## 4. The API

GitHub Pages only serves this static page. Keys, HWID locking, the ad postback
and the protected farm script live in **KeyHub** (`../keyhub` on the server).

Host KeyHub with HTTPS (VPS + nginx, or Render/Fly), then set
`window.KEYHUB_API` to that domain.

Set your provider link + postback in KeyHub's `.env`:

```dotenv
AD_PROVIDERS=lootlabs
AD_VERIFY_MODE=postback
AD_LOOTLABS_URL=https://loot-link.com/s?XXXX&puid={token}
```

Postback URL to paste in the LootLabs panel:

```
https://YOUR-KEYHUB-DOMAIN/api/v1/ad/postback?secret=YOUR_AD_CALLBACK_SECRET
```
