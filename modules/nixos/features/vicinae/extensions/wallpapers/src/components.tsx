import {
	Action,
	ActionPanel,
	Alert,
	Color,
	confirmAlert,
	Detail,
	Grid,
	Icon,
	showToast,
	Toast,
} from "@vicinae/api";
import type { ReactNode } from "react";
import {
	addFavourite,
	ensureDownloaded,
	removeFavourite,
	setWallpaper,
	type Wallpaper,
	wallpaperLicenseLabel,
} from "./lib";

async function confirmNonFree(w: Wallpaper, verb: string): Promise<boolean> {
	if (w.free) return true;
	return confirmAlert({
		title: `${verb} a copyrighted image?`,
		message: `"${w.title}" is marked © ${w.creator || "copyright holder"} and is not openly licensed. Use it only for personal display.`,
		icon: Icon.Warning,
		primaryAction: { title: verb, style: Alert.ActionStyle.Destructive },
	});
}

async function withToast(title: string, fn: () => Promise<string>): Promise<void> {
	const toast = await showToast({ style: Toast.Style.Animated, title });
	try {
		const msg = await fn();
		toast.style = Toast.Style.Success;
		toast.title = msg;
	} catch (e) {
		toast.style = Toast.Style.Failure;
		toast.title = "Failed";
		toast.message = e instanceof Error ? e.message : String(e);
	}
}

export async function applyWallpaper(w: Wallpaper): Promise<void> {
	if (!(await confirmNonFree(w, "Apply"))) return;
	await withToast("Applying wallpaper…", async () => {
		const file = await ensureDownloaded(w);
		await setWallpaper(file);
		return "Wallpaper applied";
	});
}

export async function favouriteWallpaper(w: Wallpaper): Promise<void> {
	if (!(await confirmNonFree(w, "Save"))) return;
	await withToast("Saving to favourites…", async () => {
		await addFavourite(w);
		return "Added to favourites";
	});
}

export function WallpaperActions(props: {
	wallpaper: Wallpaper;
	isPreview?: boolean;
	isFavourite?: boolean;
	onChanged?: () => void;
}): ReactNode {
	const w = props.wallpaper;
	return (
		<ActionPanel>
			<ActionPanel.Section>
				{!props.isPreview && (
					<Action.Push
						title="Preview"
						icon={Icon.Eye}
						target={<WallpaperDetail wallpaper={w} isFavourite={props.isFavourite} />}
					/>
				)}
				<Action title="Apply Wallpaper" icon={Icon.Image} onAction={() => applyWallpaper(w)} />
				{!props.isFavourite && (
					<Action
						title="Add to Favourites"
						icon={Icon.Star}
						shortcut={{ modifiers: ["ctrl"], key: "f" }}
						onAction={() => favouriteWallpaper(w)}
					/>
				)}
			</ActionPanel.Section>
			<ActionPanel.Section>
				{w.sourceUrl && (
					<Action.OpenInBrowser
						title="Open Source Page"
						url={w.sourceUrl}
						shortcut={{ modifiers: ["ctrl"], key: "o" }}
					/>
				)}
				{w.attribution && (
					<Action.CopyToClipboard
						title="Copy Attribution"
						content={w.attribution}
						shortcut={{ modifiers: ["ctrl", "shift"], key: "c" }}
					/>
				)}
				{w.localPath && <Action.ShowInFinder path={w.localPath} />}
				{props.isFavourite && w.localPath && (
					<Action
						title="Remove from Favourites"
						icon={Icon.Trash}
						style="destructive"
						onAction={async () => {
							const path = w.localPath as string;
							await withToast("Removing…", async () => {
								await removeFavourite(path);
								return "Removed from favourites";
							});
							props.onChanged?.();
						}}
					/>
				)}
			</ActionPanel.Section>
		</ActionPanel>
	);
}

function mdEscape(s: string): string {
	return s.replace(/([\\`*_[\]<>])/g, "\\$1");
}

export function WallpaperDetail(props: {
	wallpaper: Wallpaper;
	isFavourite?: boolean;
	extraMarkdown?: string;
}): ReactNode {
	const w = props.wallpaper;
	const img = w.localPath ? `file://${encodeURI(w.localPath)}` : w.thumbnailUrl || w.imageUrl;
	const md = [
		`![${mdEscape(w.title)}](${img})`,
		"",
		`**${mdEscape(w.title)}**`,
		w.description ? `\n${mdEscape(w.description)}` : "",
		"",
		w.attribution ? `> ${mdEscape(w.attribution)}` : "> No attribution recorded.",
		props.extraMarkdown ?? "",
	].join("\n");
	return (
		<Detail
			navigationTitle={w.title}
			markdown={md}
			metadata={
				<Detail.Metadata>
					<Detail.Metadata.Label title="Title" text={w.title} />
					<Detail.Metadata.Label title="Creator" text={w.creator || "unknown"} />
					{w.creatorUrl && (
						<Detail.Metadata.Link title="Creator page" target={w.creatorUrl} text={w.creatorUrl} />
					)}
					<Detail.Metadata.TagList title="Licence">
						<Detail.Metadata.TagList.Item
							text={wallpaperLicenseLabel(w)}
							color={w.free ? Color.Green : Color.Red}
						/>
					</Detail.Metadata.TagList>
					{w.licenseUrl && (
						<Detail.Metadata.Link title="Licence deed" target={w.licenseUrl} text={w.licenseUrl} />
					)}
					<Detail.Metadata.Separator />
					<Detail.Metadata.Label title="Provider" text={w.provider} />
					{w.width && w.height ? (
						<Detail.Metadata.Label title="Size" text={`${w.width} × ${w.height}`} />
					) : null}
					{w.sourceUrl && (
						<Detail.Metadata.Link title="Source" target={w.sourceUrl} text={w.sourceUrl} />
					)}
					{w.localPath && <Detail.Metadata.Label title="File" text={w.localPath} />}
				</Detail.Metadata>
			}
			actions={<WallpaperActions wallpaper={w} isPreview isFavourite={props.isFavourite} />}
		/>
	);
}

export function WallpaperItem(props: {
	wallpaper: Wallpaper;
	isFavourite?: boolean;
	onChanged?: () => void;
}): ReactNode {
	const w = props.wallpaper;
	const licence = wallpaperLicenseLabel(w);
	return (
		<Grid.Item
			id={`${w.provider}:${w.id}`}
			title={w.title}
			subtitle={w.creator ? `${licence} · ${w.creator}` : licence}
			keywords={[w.creator, licence, w.provider].filter(Boolean)}
			content={{
				value: { source: w.thumbnailUrl, fallback: Icon.Image },
				tooltip: w.attribution || w.title,
			}}
			accessory={w.free ? undefined : { icon: Icon.Warning, tooltip: "© not free" }}
			actions={
				<WallpaperActions
					wallpaper={w}
					isFavourite={props.isFavourite}
					onChanged={props.onChanged}
				/>
			}
		/>
	);
}
