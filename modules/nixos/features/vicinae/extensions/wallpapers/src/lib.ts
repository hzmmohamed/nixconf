// Shared wallpaper model, download/sidecar handling and set-wallpaper glue.
//
// Contract with the wallpaper subsystem (set-wallpaper):
//   set-wallpaper FILE      apply FILE (regenerates the palette when needed)
//   set-wallpaper --info    JSON of the current wallpaper (file + sidecar)
//   ~/Pictures/Wallpapers/             downloads
//   ~/Pictures/Wallpapers/favourites/  favourites
//   <file>.json                        attribution sidecar (see Sidecar)
import { getPreferenceValues } from "@vicinae/api";
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
import {
	copyFile,
	mkdir,
	readFile,
	readdir,
	rename,
	unlink,
	writeFile,
} from "node:fs/promises";
import { homedir } from "node:os";
import { basename, extname, join } from "node:path";

export const WALLPAPER_DIR = join(homedir(), "Pictures", "Wallpapers");
export const FAVOURITES_DIR = join(WALLPAPER_DIR, "favourites");
export const USER_AGENT =
	"vicinae-wallpapers/0.1 (personal NixOS launcher extension; https://docs.vicinae.com)";

const IMAGE_EXTENSIONS = new Set([".jpg", ".jpeg", ".png", ".webp"]);

export type Provider = "openverse" | "wikimedia" | "nasa-apod" | "local";

export type Sidecar = {
	title: string;
	creator: string;
	creator_url: string;
	license: string;
	license_version: string;
	license_url: string;
	source_url: string;
	provider: string;
	attribution: string;
	fetched_at: string;
	sha256: string;
};

export type Wallpaper = {
	provider: Provider;
	id: string;
	title: string;
	creator: string;
	creatorUrl: string;
	license: string;
	licenseVersion: string;
	licenseUrl: string;
	sourceUrl: string;
	attribution: string;
	imageUrl: string;
	thumbnailUrl: string;
	width?: number;
	height?: number;
	description?: string;
	// false when the licence does not allow reuse (e.g. APOD with copyright)
	free: boolean;
	// set for items that already exist on disk (favourites)
	localPath?: string;
};

type Preferences = { setWallpaperCommand?: string; nasaApiKey?: string };

export function preferences(): Preferences {
	return getPreferenceValues<Preferences>();
}

// ---------------------------------------------------------------- licences

const CC_NAMES: Record<string, string> = {
	cc0: "CC0",
	pdm: "Public Domain Mark",
	by: "CC BY",
	"by-sa": "CC BY-SA",
	"by-nd": "CC BY-ND",
	"by-nc": "CC BY-NC",
	"by-nc-sa": "CC BY-NC-SA",
	"by-nc-nd": "CC BY-NC-ND",
};

export function licenseLabel(license: string, version: string): string {
	const name = CC_NAMES[license.toLowerCase()] ?? license;
	return version ? `${name} ${version}` : name;
}

export function wallpaperLicenseLabel(w: Wallpaper): string {
	if (!w.free) return "© not free";
	return licenseLabel(w.license, w.licenseVersion) || "unknown licence";
}

// Parse Wikimedia style codes ("cc-by-sa-4.0", "cc0", "pd") into the
// Openverse-style short code + version used in sidecars.
export function parseLicenseCode(code: string): {
	license: string;
	version: string;
} {
	const c = code.toLowerCase().trim();
	if (c === "cc0" || c.startsWith("cc0-") || c === "cc-zero")
		return { license: "cc0", version: "1.0" };
	if (c === "pd" || c.startsWith("pd-") || c === "public domain")
		return { license: "pdm", version: "1.0" };
	const m = c.match(/^cc-((?:by)(?:-nc)?(?:-sa|-nd)?)-([\d.]+)/);
	if (m) return { license: m[1], version: m[2] };
	return { license: code, version: "" };
}

// Only CC0 / PDM / BY / BY-SA are treated as freely reusable wallpapers.
export function isFreeLicense(license: string): boolean {
	return ["cc0", "pdm", "by", "by-sa"].includes(license.toLowerCase());
}

export function buildAttribution(
	title: string,
	creator: string,
	license: string,
	version: string,
	licenseUrl: string,
	sourceUrl: string,
): string {
	const by = creator ? ` by ${creator}` : "";
	const lic = licenseLabel(license, version);
	const licText = licenseUrl ? `${lic} (${licenseUrl})` : lic;
	return `"${title}"${by} is licensed under ${licText}. Source: ${sourceUrl}`;
}

// ----------------------------------------------------------------- network

export async function fetchJson<T>(
	url: string,
	headers: Record<string, string> = {},
): Promise<T> {
	const res = await fetch(url, {
		headers: { "User-Agent": USER_AGENT, Accept: "application/json", ...headers },
	});
	if (!res.ok) {
		let detail = "";
		try {
			detail = (await res.text()).slice(0, 200);
		} catch {
			// ignore
		}
		throw new Error(`HTTP ${res.status} for ${new URL(url).host}: ${detail}`);
	}
	return (await res.json()) as T;
}

function sanitize(s: string): string {
	return s.replace(/[^A-Za-z0-9._-]+/g, "_").slice(0, 120);
}

const CONTENT_TYPE_EXT: Record<string, string> = {
	"image/jpeg": ".jpg",
	"image/png": ".png",
	"image/webp": ".webp",
};

function extensionFor(url: string, contentType: string | null): string {
	const ct = contentType?.split(";")[0].trim().toLowerCase();
	if (ct && CONTENT_TYPE_EXT[ct]) return CONTENT_TYPE_EXT[ct];
	try {
		const ext = extname(new URL(url).pathname).toLowerCase();
		if (IMAGE_EXTENSIONS.has(ext)) return ext === ".jpeg" ? ".jpg" : ext;
	} catch {
		// ignore
	}
	return ".jpg";
}

function sidecarFor(w: Wallpaper, sha256: string): Sidecar {
	return {
		title: w.title,
		creator: w.creator,
		creator_url: w.creatorUrl,
		license: w.license,
		license_version: w.licenseVersion,
		license_url: w.licenseUrl,
		source_url: w.sourceUrl,
		provider: w.provider,
		attribution: w.attribution,
		fetched_at: new Date().toISOString(),
		sha256,
	};
}

async function findExisting(dir: string, stem: string): Promise<string | null> {
	for (const ext of [".jpg", ".png", ".webp"]) {
		const p = join(dir, stem + ext);
		if (existsSync(p) && existsSync(`${p}.json`)) return p;
	}
	return null;
}

// Download a wallpaper into ~/Pictures/Wallpapers/<provider>-<id>.<ext> with
// its attribution sidecar. Reuses an earlier download.
export async function ensureDownloaded(w: Wallpaper): Promise<string> {
	if (w.localPath) return w.localPath;
	await mkdir(WALLPAPER_DIR, { recursive: true });
	const stem = `${w.provider}-${sanitize(w.id)}`;
	const existing = await findExisting(WALLPAPER_DIR, stem);
	if (existing) return existing;

	const res = await fetch(w.imageUrl, {
		headers: { "User-Agent": USER_AGENT },
		redirect: "follow",
	});
	if (!res.ok) throw new Error(`Download failed: HTTP ${res.status}`);
	const contentType = res.headers.get("content-type");
	if (contentType && !contentType.startsWith("image/"))
		throw new Error(`Not an image (${contentType})`);
	const data = Buffer.from(await res.arrayBuffer());
	const sha256 = createHash("sha256").update(data).digest("hex");

	const file = join(WALLPAPER_DIR, stem + extensionFor(w.imageUrl, contentType));
	const tmp = `${file}.part`;
	await writeFile(tmp, data);
	await writeFile(`${file}.json`, `${JSON.stringify(sidecarFor(w, sha256), null, 2)}\n`);
	await rename(tmp, file);
	return file;
}

export async function addFavourite(w: Wallpaper): Promise<string> {
	const src = await ensureDownloaded(w);
	await mkdir(FAVOURITES_DIR, { recursive: true });
	const dest = join(FAVOURITES_DIR, basename(src));
	if (dest === src) return dest;
	await copyFile(src, dest);
	if (existsSync(`${src}.json`)) {
		await copyFile(`${src}.json`, `${dest}.json`);
	} else {
		// local file without sidecar: never invent attribution, but record hash
		const sha256 = createHash("sha256").update(await readFile(src)).digest("hex");
		await writeFile(`${dest}.json`, `${JSON.stringify(sidecarFor(w, sha256), null, 2)}\n`);
	}
	return dest;
}

export async function removeFavourite(path: string): Promise<void> {
	await unlink(path);
	if (existsSync(`${path}.json`)) await unlink(`${path}.json`);
}

// ------------------------------------------------------------ set-wallpaper

function candidates(cmd: string): string[] {
	if (cmd.includes("/")) return [cmd];
	const user = process.env.USER ?? "";
	return [
		cmd,
		...(user ? [`/etc/profiles/per-user/${user}/bin/${cmd}`] : []),
		join(homedir(), ".nix-profile", "bin", cmd),
		`/run/current-system/sw/bin/${cmd}`,
	];
}

function run(args: string[]): Promise<string> {
	const cmd = preferences().setWallpaperCommand?.trim() || "set-wallpaper";
	const tries = candidates(cmd);
	return new Promise((resolve, reject) => {
		const attempt = (i: number) => {
			execFile(
				tries[i],
				args,
				{ timeout: 120_000, maxBuffer: 4 * 1024 * 1024 },
				(err, stdout, stderr) => {
					if (err && (err as NodeJS.ErrnoException).code === "ENOENT" && i + 1 < tries.length)
						return attempt(i + 1);
					if (err) return reject(new Error(stderr.trim() || err.message));
					resolve(stdout);
				},
			);
		};
		attempt(0);
	});
}

export async function setWallpaper(file: string): Promise<void> {
	await run([file]);
}

export type CurrentInfo = { file: string; sidecar: Partial<Sidecar> };

// Lenient parser: accepts {file, ...sidecar} or {file, sidecar: {...}} /
// {path|wallpaper, attribution: {...}}.
export async function currentWallpaper(): Promise<CurrentInfo> {
	const raw = JSON.parse(await run(["--info"])) as Record<string, unknown>;
	const file = String(raw.file ?? raw.path ?? raw.wallpaper ?? raw.image ?? "");
	let sidecar: Partial<Sidecar> = raw as Partial<Sidecar>;
	for (const key of ["sidecar", "meta", "metadata", "attribution"]) {
		const v = raw[key];
		if (v && typeof v === "object") {
			sidecar = v as Partial<Sidecar>;
			break;
		}
	}
	return { file, sidecar };
}

// --------------------------------------------------------------- favourites

export function wallpaperFromSidecar(file: string, s: Partial<Sidecar> | null): Wallpaper {
	const name = basename(file);
	const license = s?.license ?? "";
	return {
		provider: "local",
		id: name,
		title: s?.title || name,
		creator: s?.creator ?? "",
		creatorUrl: s?.creator_url ?? "",
		license,
		licenseVersion: s?.license_version ?? "",
		licenseUrl: s?.license_url ?? "",
		sourceUrl: s?.source_url ?? "",
		attribution: s?.attribution ?? "",
		imageUrl: `file://${file}`,
		thumbnailUrl: `file://${file}`,
		// local files: no sidecar means unknown provenance, not "not free"
		free: s ? isFreeLicense(license) || license === "" : true,
		localPath: file,
		description: s?.provider ? `from ${s.provider}` : undefined,
	};
}

export async function readSidecar(file: string): Promise<Partial<Sidecar> | null> {
	try {
		return JSON.parse(await readFile(`${file}.json`, "utf8")) as Partial<Sidecar>;
	} catch {
		return null;
	}
}

export async function listFavourites(): Promise<Wallpaper[]> {
	let names: string[] = [];
	try {
		names = await readdir(FAVOURITES_DIR);
	} catch {
		return [];
	}
	const files = names
		.filter((n) => IMAGE_EXTENSIONS.has(extname(n).toLowerCase()))
		.sort()
		.map((n) => join(FAVOURITES_DIR, n));
	return Promise.all(files.map(async (f) => wallpaperFromSidecar(f, await readSidecar(f))));
}

// ------------------------------------------------------------------- dates

export function lastDays(n: number): Date[] {
	const out: Date[] = [];
	const now = new Date();
	for (let i = 0; i < n; i++) {
		const d = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() - i));
		out.push(d);
	}
	return out;
}

export function ymd(d: Date, sep = "-"): string {
	const y = d.getUTCFullYear();
	const m = String(d.getUTCMonth() + 1).padStart(2, "0");
	const day = String(d.getUTCDate()).padStart(2, "0");
	return [y, m, day].join(sep);
}
