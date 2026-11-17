import { Grid, Icon, showToast, Toast } from "@vicinae/api";
import { useEffect, useRef, useState } from "react";
import { WallpaperItem } from "./components";
import { fetchJson, isFreeLicense, type Wallpaper } from "./lib";

// Anonymous Openverse access: page_size <= 20, ~20 requests/min, 200/day.
const PAGE_SIZE = 20;
const MIN_WIDTH = 1920;

type OpenverseImage = {
	id: string;
	title: string | null;
	foreign_landing_url: string | null;
	url: string;
	creator: string | null;
	creator_url: string | null;
	license: string;
	license_version: string | null;
	license_url: string | null;
	provider: string | null;
	attribution: string | null;
	width: number | null;
	height: number | null;
	thumbnail: string;
	mature: boolean;
};

type OpenverseResponse = {
	result_count: number;
	page_count: number;
	page: number;
	results: OpenverseImage[];
};

function toWallpaper(r: OpenverseImage): Wallpaper {
	const title = r.title?.trim() || "Untitled";
	const source = r.foreign_landing_url || r.url;
	return {
		provider: "openverse",
		id: r.id,
		title,
		creator: r.creator ?? "",
		creatorUrl: r.creator_url ?? "",
		license: r.license,
		licenseVersion: r.license_version ?? "",
		licenseUrl: r.license_url ?? "",
		sourceUrl: source,
		attribution:
			r.attribution ??
			`"${title}"${r.creator ? ` by ${r.creator}` : ""} is licensed under ${r.license} ${r.license_version ?? ""}. Source: ${source}`,
		imageUrl: r.url,
		thumbnailUrl: r.thumbnail,
		width: r.width ?? undefined,
		height: r.height ?? undefined,
		description: r.provider ? `via Openverse from ${r.provider}` : "via Openverse",
		free: isFreeLicense(r.license),
	};
}

async function search(q: string, page: number): Promise<{ items: Wallpaper[]; hasMore: boolean }> {
	const params = new URLSearchParams({
		q,
		license: "cc0,pdm,by,by-sa",
		aspect_ratio: "wide",
		size: "large",
		mature: "false",
		page_size: String(PAGE_SIZE),
		page: String(page),
	});
	const data = await fetchJson<OpenverseResponse>(`https://api.openverse.org/v1/images/?${params}`);
	const items = data.results
		.filter((r) => !r.mature && (r.width ?? 0) >= MIN_WIDTH && (r.width ?? 0) > (r.height ?? 0))
		.map(toWallpaper);
	return { items, hasMore: page < data.page_count };
}

export default function SearchOpenverse() {
	const [query, setQuery] = useState("");
	const [items, setItems] = useState<Wallpaper[]>([]);
	const [page, setPage] = useState(1);
	const [hasMore, setHasMore] = useState(false);
	const [isLoading, setIsLoading] = useState(false);
	const current = useRef("");

	useEffect(() => {
		const q = query.trim();
		current.current = q;
		setItems([]);
		setPage(1);
		setHasMore(false);
		if (q.length < 2) return;
		// debounce: anonymous rate limit is ~20 requests/min
		const t = setTimeout(async () => {
			setIsLoading(true);
			try {
				const res = await search(q, 1);
				if (current.current !== q) return;
				setItems(res.items);
				setHasMore(res.hasMore);
			} catch (e) {
				if (current.current === q)
					showToast({ style: Toast.Style.Failure, title: "Openverse search failed", message: String(e) });
			} finally {
				if (current.current === q) setIsLoading(false);
			}
		}, 600);
		return () => clearTimeout(t);
	}, [query]);

	const loadMore = async () => {
		const q = current.current;
		if (!q || isLoading) return;
		setIsLoading(true);
		try {
			const res = await search(q, page + 1);
			if (current.current !== q) return;
			const seen = new Set(items.map((i) => i.id));
			setItems([...items, ...res.items.filter((i) => !seen.has(i.id))]);
			setPage(page + 1);
			setHasMore(res.hasMore);
		} catch (e) {
			showToast({ style: Toast.Style.Failure, title: "Openverse search failed", message: String(e) });
			setHasMore(false);
		} finally {
			setIsLoading(false);
		}
	};

	return (
		<Grid
			columns={4}
			aspectRatio="16/9"
			fit={Grid.Fit.Fill}
			filtering={false}
			throttle
			isLoading={isLoading}
			searchBarPlaceholder="Search openly-licensed wallpapers (CC0, PDM, CC BY, CC BY-SA)…"
			onSearchTextChange={setQuery}
			pagination={{ onLoadMore: loadMore, hasMore }}
		>
			{query.trim().length < 2 ? (
				<Grid.EmptyView
					icon={Icon.MagnifyingGlass}
					title="Search Openverse"
					description="Wide images, at least 1920px, licensed CC0 / PDM / CC BY / CC BY-SA"
				/>
			) : (
				<Grid.Section title={`Openverse · ${items.length} results ≥ ${MIN_WIDTH}px`}>
					{items.map((w) => (
						<WallpaperItem key={w.id} wallpaper={w} />
					))}
				</Grid.Section>
			)}
		</Grid>
	);
}
