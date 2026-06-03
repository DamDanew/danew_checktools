import { chromium } from 'playwright';
import { existsSync } from 'fs';
import { resolve } from 'path';

const filePath = 'file:///H:/Danew_CheckTool/WinPe_local/reports/timeline-raw.html';

const browser = await chromium.launch({ headless: true, args: ['--allow-file-access-from-files'] });
const page = await browser.newPage();
await page.setViewportSize({ width: 1280, height: 800 });

await page.goto(filePath, { waitUntil: 'domcontentloaded', timeout: 15000 });
await page.waitForTimeout(1500);

// ── TEST 1: Navbar ──
const navbar = page.locator('.report-navbar-sticky').first();
const navbarBg = await navbar.evaluate(el => getComputedStyle(el).backgroundColor);
const navLinks = await page.locator('.nav-link').all();
const seps     = await page.locator('.nav-sep').all();

// ── TEST 2: Lien actif ──
const activeLink = page.locator('.nav-link.active').first();
const activeBg   = await activeLink.evaluate(el => getComputedStyle(el).backgroundColor);
const activeColor = await activeLink.evaluate(el => getComputedStyle(el).color);
const activeText = await activeLink.textContent();

// ── TEST 3: Liens non-actifs ──
const inactiveLink  = page.locator('.nav-link:not(.active)').first();
const inactiveColor = await inactiveLink.evaluate(el => getComputedStyle(el).color);
const inactiveText  = await inactiveLink.textContent();

// ── TEST 4: Toolbar 2 rangées ──
const primaryRow   = page.locator('.toolbar-row.primary').first();
const secondaryRow = page.locator('.toolbar-row.secondary').first();
const primaryVisible   = await primaryRow.isVisible();
const secondaryVisible = await secondaryRow.isVisible();

// ── TEST 5: Police ──
const bodyFont = await page.evaluate(() => getComputedStyle(document.body).fontFamily);

// ── SCREENSHOT light ──
await page.screenshot({ path: 'H:/Danew_CheckTool/pw-light.png' });

// ── TEST 6: Dark mode (touche T) ──
await page.keyboard.press('t');
await page.waitForTimeout(600);
const isDark       = await page.evaluate(() => document.body.classList.contains('theme-dark'));
const darkNavBg    = await navbar.evaluate(el => getComputedStyle(el).backgroundColor);
const darkLinkClr  = await inactiveLink.evaluate(el => getComputedStyle(el).color);
const darkActiveBg = await activeLink.evaluate(el => getComputedStyle(el).backgroundColor);

// ── SCREENSHOT dark ──
await page.screenshot({ path: 'H:/Danew_CheckTool/pw-dark.png' });

// ── Calcul luminosité ──
function lum(css) {
    const m = css.match(/\d+/g);
    if (!m) return 0;
    return Math.round(parseInt(m[0])*0.299 + parseInt(m[1])*0.587 + parseInt(m[2])*0.114);
}
function ok(v)  { return v ? '✅' : '❌'; }
function okn(n) { return n > 80 ? '✅ lisible' : n > 40 ? '⚠️  limite' : '❌ illisible'; }

console.log('═══════════════════════════════════════════════════════');
console.log('  PLAYWRIGHT — VERIFICATION COULEURS / UI');
console.log('═══════════════════════════════════════════════════════');
console.log('');
console.log('[ NAVBAR — LIGHT MODE ]');
console.log('  Fond navbar       :', navbarBg);
console.log('  Nb liens          :', navLinks.length, ok(navLinks.length >= 5));
console.log('  Nb séparateurs    :', seps.length,     ok(seps.length >= 4));
console.log('');
console.log('[ LIEN ACTIF — LIGHT ]');
console.log('  Texte             :', activeText.trim());
console.log('  Background        :', activeBg);
console.log('  Couleur texte     :', activeColor, '— lum:', lum(activeColor), okn(lum(activeColor)));
console.log('');
console.log('[ LIENS NON-ACTIFS — LIGHT ]');
console.log('  Texte exemple     :', inactiveText.trim());
console.log('  Couleur           :', inactiveColor, '— lum:', lum(inactiveColor), okn(lum(inactiveColor)));
console.log('');
console.log('[ TOOLBAR ]');
console.log('  Rangée principale :', ok(primaryVisible));
console.log('  Rangée secondaire :', ok(secondaryVisible));
console.log('');
console.log('[ POLICE ]');
console.log('  Font-family       :', bodyFont.split(',')[0].trim());
console.log('  Segoe UI présent  :', ok(bodyFont.includes('Segoe UI')));
console.log('  Bahnschrift absent:', ok(!bodyFont.includes('Bahnschrift')));
console.log('');
console.log('[ DARK MODE (touche T) ]');
console.log('  Classe theme-dark :', ok(isDark));
console.log('  Fond navbar dark  :', darkNavBg);
console.log('  Liens dark        :', darkLinkClr, '— lum:', lum(darkLinkClr), okn(lum(darkLinkClr)));
console.log('  Lien actif dark   :', darkActiveBg);
console.log('');
console.log('[ SCREENSHOTS ]');
console.log('  Light             :', existsSync('H:/Danew_CheckTool/pw-light.png') ? '✅ pw-light.png' : '❌');
console.log('  Dark              :', existsSync('H:/Danew_CheckTool/pw-dark.png')  ? '✅ pw-dark.png'  : '❌');
console.log('═══════════════════════════════════════════════════════');

await browser.close();
