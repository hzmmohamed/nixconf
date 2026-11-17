import { Cache, Grid, showToast, Toast } from "@vicinae/api";
import { useEffect, useState } from "react";
import { WallpaperItem } from "./components";
import {
	buildAttribution,
	fetchJson,
	isFreeLicense,
	lastDays,
	parseLicenseCode,
	type Wallpaper,
	ymd,
} from "./lib";

const DAYS = 14;
const cache = new Cache({ namespace: "wikimedia-potd" });

type FeedImage = {
	title: string;
	thumbnail?: { source: string; width: number; height: number };
	image: { source: string; width: number; height: number };
	file_page: string;
	artist?: { text?: string; html?: string };
	credit?: { text?: string };
	license?: { type?: string; code?: string; url?: string };
	description?: { text?: string };
};

type FeedResponse = { image?: FeedImage };

function toWallpaper(img: FeedImage, date: string): Wallpaper {
	const title = img.title.replace(/^File:/, "").replace(/\.[a-z]+$/i, "");
	const creator = img.artist?.text?.trim() ?? "";
	const creatorUrl = img.artist?.html?.match(/href="([^"]+)"/)?.[1] ?? "";
	const { license, version } = parseLicenseCode(img.license?.code ?? img.license?.type ?? "");
	const licenseUrl = img.license?.url ?? "";
	return {
		provider: "wikimedia",
		id: date,
		title,
		creator,
		creatorUrl: creatorUrl.startsWith("//") ? `https:${creatorUrl}` : creatorUrl,
		license,
		licenseVersion: version,
		licenseUrl,
		sourceUrl: img.file_page,
		attribution: buildAttribution(title, creator, license, version, licenseUrl, img.file_page),
		imageUrl: img.image.source,
		thumbnailUrl: img.thumbnail?.source ?? img.image.source,
		width: img.image.width,
		height: img.image.height,
		description: [`Picture of the day ${date}`, img.description?.text].filter(Boolean).join(" — "),
		free: isFreeLicense(license),
	};
}

async function fetchDay(d: Date): Promise<Wallpaper | null> {
	const key = ymd(d);
	const hit = cache.get(key);
	if (hit) return JSON.parse(hit) as Wallpaper | null;
	const data = await fetchJson<FeedResponse>(
		`https://api.wikimedia.org/feed/v1/wikipedia/en/featured/${ymd(d, "/")}`,
	);
	const w = data.image ? toWallpaper(data.image, key) : null;
	// past days never change; keep them for a week
	cache.set(key, JSON.stringify(w), { ttl: 7 * 24 * 3600 * 1000 });
	return w;
}

export default function WikimediaPotd() {
	const [items, setItems] = useState<Wallpaper[]>([]);
	const [isLoading, setIsLoading] = useState(true);

	useEffect(() => {
		(async () => {
			const results = await Promise.allSettled(lastDays(DAYS).map(fetchDay));
			const ok = results.flatMap((r) => (r.status === "fulfilled" && r.value ? [r.value] : []));
			const failed = results.filter((r) => r.status === "rejected").length;
			if (failed)
				showToast({ style: Toast.Style.Failure, title: `${failed} day(s) failed to load` });
			setItems(ok);
			setIsLoading(false);
		})();
	}, []);

	const wide = items.filter((w) => (w.width ?? 0) >= (w.height ?? 0));
	const tall = items.filter((w) => (w.width ?? 0) < (w.height ?? 0));

	return (
		<Grid columns={4} aspectRatio="16/9" fit={Grid.Fit.Fill} isLoading={isLoading} searchBarPlaceholder="Filter pictures of the day…">
			<Grid.Section title="Landscape">
				{wide.map((w) => (
					<WallpaperItem key={w.id} wallpaper={w} />
				))}
			</Grid.Section>
			<Grid.Section title="Portrait">
				{tall.map((w) => (
					<WallpaperItem key={w.id} wallpaper={w} />
				))}
			</Grid.Section>
		</Grid>
	);
}
