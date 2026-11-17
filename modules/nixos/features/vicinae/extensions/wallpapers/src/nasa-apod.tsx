import { Cache, Grid, Icon, showToast, Toast } from "@vicinae/api";
import { useEffect, useState } from "react";
import { WallpaperItem } from "./components";
import { fetchJson, lastDays, preferences, type Wallpaper, ymd } from "./lib";

const DAYS = 14;
const cache = new Cache({ namespace: "nasa-apod" });

type Apod = {
	date: string;
	title: string;
	explanation?: string;
	media_type: string;
	url?: string;
	hdurl?: string;
	thumbnail_url?: string;
	copyright?: string | null;
};

function toWallpaper(a: Apod): Wallpaper {
	const copyright = a.copyright?.replace(/\s+/g, " ").trim() ?? "";
	const ymdCompact = a.date.replace(/-/g, "").slice(2);
	const sourceUrl = `https://apod.nasa.gov/apod/ap${ymdCompact}.html`;
	const free = !copyright;
	return {
		provider: "nasa-apod",
		id: a.date,
		title: a.title,
		creator: copyright || "NASA",
		creatorUrl: "",
		license: free ? "pdm" : "copyright",
		licenseVersion: free ? "1.0" : "",
		licenseUrl: free ? "https://www.nasa.gov/nasa-brand-center/images-and-media/" : "",
		sourceUrl,
		attribution: free
			? `"${a.title}" — NASA Astronomy Picture of the Day ${a.date}, public domain (NASA media usage guidelines). Source: ${sourceUrl}`
			: `"${a.title}" — © ${copyright}. NASA Astronomy Picture of the Day ${a.date}; not openly licensed. Source: ${sourceUrl}`,
		imageUrl: a.hdurl || a.url || "",
		thumbnailUrl: a.url || a.hdurl || "",
		description: a.explanation,
		free,
	};
}

// APOD occasionally serves site chrome instead of the picture (e.g. a logo)
function isRealImage(a: Apod): boolean {
	const u = a.hdurl || a.url || "";
	return a.media_type === "image" && !!u && !/\/wp-content\/themes\/|logo/i.test(u);
}

async function load(): Promise<Wallpaper[]> {
	const days = lastDays(DAYS);
	const start = ymd(days[days.length - 1]);
	const end = ymd(days[0]);
	const key = `${start}_${end}`;
	const hit = cache.get(key);
	let entries: Apod[];
	if (hit) {
		entries = JSON.parse(hit) as Apod[];
	} else {
		const apiKey = preferences().nasaApiKey?.trim() || "DEMO_KEY";
		const params = new URLSearchParams({ api_key: apiKey, start_date: start, end_date: end, thumbs: "true" });
		try {
			entries = await fetchJson<Apod[]>(`https://api.nasa.gov/planetary/apod?${params}`);
		} catch (e) {
			// today's entry may not be published yet (US time zones)
			params.set("end_date", ymd(days[1]));
			entries = await fetchJson<Apod[]>(`https://api.nasa.gov/planetary/apod?${params}`);
			void e;
		}
		// DEMO_KEY allows very few requests per hour: cache for 6 hours
		cache.set(key, JSON.stringify(entries), { ttl: 6 * 3600 * 1000 });
	}
	return entries.filter(isRealImage).reverse().map(toWallpaper);
}

export default function NasaApod() {
	const [items, setItems] = useState<Wallpaper[]>([]);
	const [isLoading, setIsLoading] = useState(true);

	useEffect(() => {
		load()
			.then(setItems)
			.catch((e) => showToast({ style: Toast.Style.Failure, title: "NASA APOD failed", message: String(e) }))
			.finally(() => setIsLoading(false));
	}, []);

	return (
		<Grid columns={4} aspectRatio="16/9" fit={Grid.Fit.Fill} isLoading={isLoading} searchBarPlaceholder="Filter APOD images…">
			{!isLoading && items.length === 0 ? (
				<Grid.EmptyView icon={Icon.Image} title="No APOD images" description="The API returned no usable images for the last two weeks" />
			) : (
				<Grid.Section title="Astronomy Picture of the Day · © entries are not free">
					{items.map((w) => (
						<WallpaperItem key={w.id} wallpaper={w} />
					))}
				</Grid.Section>
			)}
		</Grid>
	);
}
