package dev.universaltmux.android

import android.graphics.BitmapFactory
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.rememberTransformableState
import androidx.compose.foundation.gestures.transformable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.automirrored.filled.MenuBook
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Slideshow
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.time.temporal.TemporalAdjusters

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun WeeklyProgressScreen(vm: AppViewModel) {
    val theme = LocalTheme.current
    val catalog = vm.weeklyProgressCatalog
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var selectedProjectId by rememberSaveable { mutableStateOf<String?>(null) }
    var selectedWeek by rememberSaveable { mutableStateOf(currentMonday().toString()) }
    var calendarMode by rememberSaveable { mutableStateOf(false) }
    var showProjects by remember { mutableStateOf(false) }
    var reader by remember { mutableStateOf<WeeklyProgressGenerationSummary?>(null) }
    var report by remember { mutableStateOf<WeeklyProgressGenerationSummary?>(null) }
    var confirmGeneration by remember { mutableStateOf(false) }
    var pendingDownload by remember { mutableStateOf<WeeklyProgressGenerationSummary?>(null) }
    var downloadProgress by remember { mutableStateOf<Pair<Long, Long>?>(null) }
    var localMessage by remember { mutableStateOf<String?>(null) }

    val createDeck = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument(
            "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        )
    ) { uri ->
        val generation = pendingDownload
        pendingDownload = null
        if (uri == null || generation == null) return@rememberLauncherForActivityResult
        val host = vm.weeklyProgressHost()
        if (host == null) {
            localMessage = "The Mac must be reachable to download this PowerPoint."
            return@rememberLauncherForActivityResult
        }
        scope.launch {
            downloadProgress = 0L to -1L
            val ok = withContext(Dispatchers.IO) {
                context.contentResolver.openOutputStream(uri)?.use { output ->
                    WeeklyProgressNet.downloadDeck(host, generation.id, output) { read, total ->
                        scope.launch { downloadProgress = read to total }
                    }
                } ?: false
            }
            downloadProgress = null
            localMessage = if (ok) "PowerPoint saved." else "The PowerPoint could not be downloaded."
        }
    }

    fun download(generation: WeeklyProgressGenerationSummary) {
        pendingDownload = generation
        createDeck.launch(deckFilename(generation))
    }

    LaunchedEffect(Unit) { vm.refreshWeeklyProgress(force = true) }
    LaunchedEffect(catalog.projects) {
        if (selectedProjectId != null && catalog.projects.none { it.id == selectedProjectId }) {
            selectedProjectId = null
        }
    }

    val selectedProject = catalog.projects.firstOrNull { it.id == selectedProjectId }
    val selectedWeekDate = runCatching { LocalDate.parse(selectedWeek) }.getOrElse { currentMonday() }
    val weekGenerations = catalog.generations.filter { generation ->
        generation.weekStart == selectedWeek &&
            (selectedProjectId == null || generation.projectId == selectedProjectId)
    }
    val existingForSelection = selectedProjectId != null && weekGenerations.isNotEmpty()

    Column(Modifier.fillMaxSize().background(theme.bgDeep)) {
        Column(
            Modifier.fillMaxWidth().background(theme.panel).padding(horizontal = 14.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Surface(
                    color = theme.selection,
                    shape = RoundedCornerShape(10.dp),
                    modifier = Modifier.weight(1f).clickable { showProjects = true },
                ) {
                    Row(
                        Modifier.padding(horizontal = 13.dp, vertical = 11.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            selectedProject?.name ?: "All projects",
                            color = theme.text,
                            fontSize = 15.sp,
                            fontWeight = FontWeight.SemiBold,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f),
                        )
                        Icon(Icons.Filled.KeyboardArrowDown, null, tint = theme.dim, modifier = Modifier.size(19.dp))
                    }
                }
                Spacer(Modifier.width(8.dp))
                IconButton(onClick = { vm.refreshWeeklyProgress(force = true) }) {
                    Icon(Icons.Filled.Refresh, "Refresh", tint = theme.dim)
                }
            }

            if (!calendarMode) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    FilledTonalIconButton(
                        onClick = { selectedWeek = selectedWeekDate.minusWeeks(1).toString() },
                        colors = IconButtonDefaults.filledTonalIconButtonColors(containerColor = theme.selection),
                    ) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Previous week", tint = theme.text) }
                    Column(
                        Modifier.weight(1f).padding(horizontal = 12.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        Text(weekRange(selectedWeekDate), color = theme.text, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                        Text("Monday through Sunday", color = theme.faint, fontSize = 11.sp)
                    }
                    FilledTonalIconButton(
                        onClick = { selectedWeek = selectedWeekDate.plusWeeks(1).toString() },
                        colors = IconButtonDefaults.filledTonalIconButtonColors(containerColor = theme.selection),
                    ) { Icon(Icons.AutoMirrored.Filled.ArrowForward, "Next week", tint = theme.text) }
                }
            }

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                if (selectedProjectId != null) {
                    FilterChip(
                        selected = !calendarMode,
                        onClick = { calendarMode = false },
                        label = { Text("Selected week") },
                        leadingIcon = { Icon(Icons.Filled.CalendarMonth, null, modifier = Modifier.size(16.dp)) },
                        colors = weeklyChipColors(theme),
                    )
                    FilterChip(
                        selected = calendarMode,
                        onClick = { calendarMode = true },
                        label = { Text("Calendar") },
                        leadingIcon = { Icon(Icons.Filled.History, null, modifier = Modifier.size(16.dp)) },
                        colors = weeklyChipColors(theme),
                    )
                } else {
                    Text(
                        "${catalog.projects.size} projects",
                        color = theme.faint,
                        fontSize = 12.sp,
                        modifier = Modifier.padding(start = 4.dp),
                    )
                }
                Spacer(Modifier.weight(1f))
                if (selectedProjectId != null && !calendarMode) {
                    Button(
                        onClick = {
                            if (existingForSelection) confirmGeneration = true
                            else vm.generateWeeklyProgress(selectedProjectId!!, selectedWeek)
                        },
                        enabled = vm.weeklyProgressProviderAvailable &&
                            !vm.weeklyProgressActionBusy && catalog.activeOperation == null,
                        colors = ButtonDefaults.buttonColors(
                            containerColor = theme.accent,
                            contentColor = if (theme.isLight) Color.White else theme.bg,
                        ),
                        shape = RoundedCornerShape(10.dp),
                    ) {
                        if (vm.weeklyProgressActionBusy) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(15.dp), strokeWidth = 2.dp,
                                color = if (theme.isLight) Color.White else theme.bg,
                            )
                        } else Icon(Icons.Filled.PlayArrow, null, modifier = Modifier.size(17.dp))
                        Spacer(Modifier.width(5.dp))
                        Text("Generate")
                    }
                }
            }
        }

        val message = localMessage ?: vm.weeklyProgressError
        if (message != null) {
            Row(
                Modifier.fillMaxWidth().background(
                    if (vm.weeklyProgressProviderAvailable) theme.selection else theme.waiting.copy(alpha = .12f)
                ).padding(horizontal = 15.dp, vertical = 9.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    if (vm.weeklyProgressProviderAvailable) Icons.Filled.CheckCircle else Icons.Filled.ErrorOutline,
                    null,
                    tint = if (vm.weeklyProgressProviderAvailable) theme.live else theme.waiting,
                    modifier = Modifier.size(17.dp),
                )
                Spacer(Modifier.width(8.dp))
                Text(message, color = theme.dim, fontSize = 12.sp, modifier = Modifier.weight(1f))
                TextButton(onClick = { localMessage = null; vm.clearWeeklyProgressError() }) {
                    Text("Dismiss", color = theme.accent, fontSize = 12.sp)
                }
            }
        }

        downloadProgress?.let { (read, total) ->
            LinearProgressIndicator(
                progress = { if (total > 0) (read.toFloat() / total).coerceIn(0f, 1f) else 0f },
                modifier = Modifier.fillMaxWidth(),
                color = theme.accent,
                trackColor = theme.border,
            )
        }

        catalog.activeOperation?.let { operation ->
            ActiveReviewBanner(operation, theme)
        }

        when {
            vm.weeklyProgressRefreshing && catalog.projects.isEmpty() -> WeeklyLoading(theme)
            catalog.projects.isEmpty() -> WeeklyEmpty(
                title = "No Weekly Progress projects",
                body = "Create a project in Argus on your Mac. It will appear here automatically.",
                theme = theme,
            )
            calendarMode && selectedProjectId != null -> {
                val sections = catalog.generations
                    .filter { it.projectId == selectedProjectId }
                    .groupBy { it.weekStart }
                    .toSortedMap(compareByDescending { it })
                if (sections.isEmpty()) WeeklyEmpty(
                    "No reviews yet", "Generate the first review from Selected week.", theme
                ) else LazyColumn(
                    Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(14.dp),
                    verticalArrangement = Arrangement.spacedBy(18.dp),
                ) {
                    sections.forEach { (week, versions) ->
                        item(key = "header-$week") {
                            CalendarWeekHeader(week, versions.size, theme)
                        }
                        items(versions.sortedByDescending { it.createdAt }, key = { it.id }) { generation ->
                            WeeklyReviewCard(
                                generation, versions.size, vm, theme,
                                onRead = { reader = generation },
                                onReport = { report = generation },
                                onDownload = { download(generation) },
                                onResume = { vm.resumeWeeklyProgress(generation.id) },
                            )
                        }
                    }
                }
            }
            else -> {
                val entries = if (selectedProjectId == null) {
                    weekGenerations.groupBy { it.projectId }.values.mapNotNull { versions ->
                        val newest = versions.maxByOrNull { it.createdAt } ?: return@mapNotNull null
                        // A replacement review is persisted before it has slides.
                        // Keep the previous readable edition on the All shelf while
                        // the global progress banner shows the new run in flight.
                        if (newest.slideCount == 0 && newest.isActive) {
                            versions
                                .filter { it.slideCount > 0 }
                                .maxByOrNull { it.createdAt }
                                ?: newest
                        } else newest
                    }.sortedBy { it.projectName.lowercase() }
                } else weekGenerations.sortedByDescending { it.createdAt }
                if (entries.isEmpty()) WeeklyEmpty(
                    title = if (selectedProjectId == null) "No reviews this week" else "Nothing generated for this week",
                    body = if (selectedProjectId == null)
                        "Choose a project to create its review."
                    else "Generate a research review when you are ready.",
                    theme = theme,
                ) else LazyColumn(
                    Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(14.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    items(entries, key = { it.id }) { generation ->
                        val versions = weekGenerations.count { it.projectId == generation.projectId }
                        WeeklyReviewCard(
                            generation, versions, vm, theme,
                            onRead = { reader = generation },
                            onReport = { report = generation },
                            onDownload = { download(generation) },
                            onResume = { vm.resumeWeeklyProgress(generation.id) },
                        )
                    }
                }
            }
        }
    }

    if (showProjects) {
        ModalBottomSheet(
            onDismissRequest = { showProjects = false },
            containerColor = theme.panel,
            contentColor = theme.text,
        ) {
            Text(
                "PROJECT",
                color = theme.faint,
                fontSize = 11.sp,
                fontWeight = FontWeight.Bold,
                letterSpacing = 1.4.sp,
                modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp),
            )
            ProjectChoice(
                name = "All projects",
                detail = "One shelf for the selected week",
                selected = selectedProjectId == null,
                theme = theme,
            ) { selectedProjectId = null; calendarMode = false; showProjects = false }
            LazyColumn(Modifier.fillMaxWidth().heightIn(max = 560.dp)) {
                items(catalog.projects, key = { it.id }) { project ->
                    ProjectChoice(
                        name = project.name,
                        detail = projectSourceCount(project),
                        selected = selectedProjectId == project.id,
                        theme = theme,
                    ) { selectedProjectId = project.id; showProjects = false }
                }
            }
            Spacer(Modifier.height(24.dp))
        }
    }

    if (confirmGeneration && selectedProjectId != null) {
        AlertDialog(
            onDismissRequest = { confirmGeneration = false },
            containerColor = theme.panel,
            titleContentColor = theme.text,
            textContentColor = theme.dim,
            title = { Text("Create another version?") },
            text = { Text("This week already has a review. The existing version will remain available.") },
            dismissButton = { TextButton(onClick = { confirmGeneration = false }) { Text("Cancel") } },
            confirmButton = {
                Button(onClick = {
                    confirmGeneration = false
                    vm.generateWeeklyProgress(selectedProjectId!!, selectedWeek)
                }) { Text("Generate version") }
            },
        )
    }

    reader?.let { generation ->
        WeeklySlideReader(
            generation = generation,
            vm = vm,
            theme = theme,
            onClose = { reader = null },
            onDownload = { download(generation) },
            onReport = { report = generation },
        )
    }
    report?.let { generation ->
        WeeklyReportReader(generation, vm, theme) { report = null }
    }
}

@Composable
private fun ActiveReviewBanner(operation: WeeklyProgressActiveOperation, theme: ThemePalette) {
    val steps = listOf("collectingEvidence", "reconstructingResearch", "draftingSlides", "auditingSlides")
    val activeIndex = steps.indexOf(operation.stage).coerceAtLeast(0)
    Column(
        Modifier.fillMaxWidth().background(theme.accent.copy(alpha = .09f)).padding(horizontal = 15.dp, vertical = 11.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            CircularProgressIndicator(modifier = Modifier.size(15.dp), strokeWidth = 2.dp, color = theme.accent)
            Spacer(Modifier.width(9.dp))
            Text(operation.projectName, color = theme.text, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.weight(1f))
            Text(stageTitle(operation.stage), color = theme.accent, fontSize = 11.sp)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(5.dp)) {
            steps.forEachIndexed { index, _ ->
                Box(
                    Modifier.weight(1f).height(3.dp).clip(RoundedCornerShape(2.dp))
                        .background(if (index <= activeIndex) theme.accent else theme.border)
                )
            }
        }
    }
}

@Composable
private fun WeeklyReviewCard(
    generation: WeeklyProgressGenerationSummary,
    versionCount: Int,
    vm: AppViewModel,
    theme: ThemePalette,
    onRead: () -> Unit,
    onReport: () -> Unit,
    onDownload: () -> Unit,
    onResume: () -> Unit,
) {
    Surface(
        color = theme.panelAlt,
        shape = RoundedCornerShape(14.dp),
        border = androidx.compose.foundation.BorderStroke(1.dp, theme.border),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column {
            Box(
                Modifier.fillMaxWidth().aspectRatio(16f / 8.3f)
                    .background(theme.selection)
                    .clickable(enabled = generation.slideCount > 0, onClick = onRead),
            ) {
                if (generation.slideCount > 0) {
                    RemoteSlideImage(
                        vm = vm,
                        generationId = generation.id,
                        slide = 1,
                        contentDescription = "${generation.projectName} cover slide",
                        modifier = Modifier.fillMaxSize(),
                        sampleSize = 2,
                    )
                } else {
                    Column(Modifier.align(Alignment.Center), horizontalAlignment = Alignment.CenterHorizontally) {
                        Icon(Icons.Filled.Slideshow, null, tint = theme.faint, modifier = Modifier.size(30.dp))
                        Spacer(Modifier.height(7.dp))
                        Text(stageTitle(generation.stage), color = theme.dim, fontSize = 12.sp)
                    }
                }
                Surface(
                    color = stateColor(generation.state, theme).copy(alpha = .92f),
                    shape = RoundedCornerShape(bottomStart = 8.dp),
                    modifier = Modifier.align(Alignment.TopEnd),
                ) {
                    Text(
                        stateTitle(generation),
                        color = if (theme.isLight) Color.White else theme.bg,
                        fontSize = 10.sp,
                        fontWeight = FontWeight.Bold,
                        modifier = Modifier.padding(horizontal = 9.dp, vertical = 5.dp),
                    )
                }
            }
            Column(Modifier.padding(13.dp), verticalArrangement = Arrangement.spacedBy(9.dp)) {
                Row(verticalAlignment = Alignment.Top) {
                    Column(Modifier.weight(1f)) {
                        Text(
                            generation.projectName,
                            color = theme.text,
                            fontSize = 16.sp,
                            fontWeight = FontWeight.SemiBold,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                        )
                        Text(
                            "${weekRange(LocalDate.parse(generation.weekStart))}  ·  ${versionLabel(versionCount)}",
                            color = theme.faint,
                            fontSize = 11.sp,
                        )
                    }
                    if (generation.slideCount > 0) {
                        Text("${generation.slideCount} slides", color = theme.dim, fontSize = 11.sp)
                    }
                }
                generation.error?.let {
                    Text(it, color = theme.bad, fontSize = 11.sp, maxLines = 3, overflow = TextOverflow.Ellipsis)
                }
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    if (generation.slideCount > 0) {
                        TextButton(onClick = onRead) {
                            Icon(Icons.Filled.Slideshow, null, modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(4.dp)); Text("Read")
                        }
                    }
                    if (generation.hasReport) {
                        TextButton(onClick = onReport) {
                            Icon(Icons.AutoMirrored.Filled.MenuBook, null, modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(4.dp)); Text("Report")
                        }
                    }
                    if (generation.hasDeck) {
                        TextButton(onClick = onDownload) {
                            Icon(Icons.Filled.Download, null, modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(4.dp)); Text("PPTX")
                        }
                    }
                    Spacer(Modifier.weight(1f))
                    if (generation.canResume) {
                        FilledTonalButton(
                            onClick = onResume,
                            enabled = vm.weeklyProgressProviderAvailable &&
                                !vm.weeklyProgressActionBusy && vm.weeklyProgressCatalog.activeOperation == null,
                            colors = ButtonDefaults.filledTonalButtonColors(containerColor = theme.selection),
                        ) { Text("Resume", color = theme.text) }
                    }
                }
            }
        }
    }
}

@Composable
private fun RemoteSlideImage(
    vm: AppViewModel,
    generationId: String,
    slide: Int,
    contentDescription: String?,
    modifier: Modifier = Modifier,
    contentScale: ContentScale = ContentScale.Fit,
    sampleSize: Int = 1,
) {
    val context = LocalContext.current
    var bitmap by remember(generationId, slide) { mutableStateOf<androidx.compose.ui.graphics.ImageBitmap?>(null) }
    var attempted by remember(generationId, slide) { mutableStateOf(false) }
    LaunchedEffect(generationId, slide, vm.weeklyProgressProviderAvailable) {
        attempted = false
        val bytes = withContext(Dispatchers.IO) {
            WeeklyProgressNet.slideBytes(context, vm.weeklyProgressHost(), generationId, slide)
        }
        bitmap = bytes?.let {
            BitmapFactory.decodeByteArray(
                it, 0, it.size,
                android.graphics.BitmapFactory.Options().apply { inSampleSize = sampleSize.coerceAtLeast(1) },
            )?.asImageBitmap()
        }
        attempted = true
    }
    Box(modifier, contentAlignment = Alignment.Center) {
        if (bitmap != null) {
            Image(bitmap!!, contentDescription, Modifier.fillMaxSize(), contentScale = contentScale)
        } else if (!attempted) {
            CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun WeeklySlideReader(
    generation: WeeklyProgressGenerationSummary,
    vm: AppViewModel,
    theme: ThemePalette,
    onClose: () -> Unit,
    onDownload: () -> Unit,
    onReport: () -> Unit,
) {
    val pager = rememberPagerState { generation.slideCount }
    val scope = rememberCoroutineScope()
    BackHandler(onBack = onClose)
    Dialog(
        onDismissRequest = onClose,
        properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false),
    ) {
        Column(Modifier.fillMaxSize().background(Color(0xFF090A0D))) {
            Row(
                Modifier.fillMaxWidth().background(Color(0xEE111217)).padding(horizontal = 6.dp, vertical = 5.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                IconButton(onClick = onClose) { Icon(Icons.Filled.Close, "Close", tint = Color.White) }
                Column(Modifier.weight(1f)) {
                    Text(
                        generation.projectName,
                        color = Color.White,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Text(
                        "${pager.currentPage + 1} of ${generation.slideCount}",
                        color = Color(0xFF9297A5),
                        fontSize = 11.sp,
                    )
                }
                if (generation.hasReport) {
                    IconButton(onClick = onReport) { Icon(Icons.AutoMirrored.Filled.MenuBook, "Research report", tint = Color(0xFFC7CBD5)) }
                }
                if (generation.hasDeck) {
                    IconButton(onClick = onDownload) { Icon(Icons.Filled.Download, "Download PowerPoint", tint = Color(0xFFC7CBD5)) }
                }
            }
            HorizontalPager(state = pager, modifier = Modifier.weight(1f).fillMaxWidth()) { page ->
                ZoomableRemoteSlide(vm, generation.id, page + 1)
            }
            Row(
                Modifier.fillMaxWidth().background(Color(0xEE111217)).padding(horizontal = 12.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                FilledTonalButton(
                    onClick = {
                        scope.launch { pager.animateScrollToPage((pager.currentPage - 1).coerceAtLeast(0)) }
                    },
                    enabled = pager.currentPage > 0,
                    contentPadding = PaddingValues(horizontal = 13.dp, vertical = 8.dp),
                    colors = readerButtonColors(),
                ) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, null, Modifier.size(17.dp))
                    Spacer(Modifier.width(5.dp))
                    Text("Previous", fontSize = 12.sp)
                }
                Column(
                    Modifier.weight(1f),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Text(
                        "${pager.currentPage + 1} / ${generation.slideCount}",
                        color = Color(0xFFD7DAE2),
                        fontSize = 12.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text("Swipe · pinch to zoom", color = Color(0xFF777D8B), fontSize = 9.sp)
                }
                FilledTonalButton(
                    onClick = {
                        scope.launch {
                            pager.animateScrollToPage(
                                (pager.currentPage + 1).coerceAtMost(generation.slideCount - 1)
                            )
                        }
                    },
                    enabled = pager.currentPage < generation.slideCount - 1,
                    contentPadding = PaddingValues(horizontal = 13.dp, vertical = 8.dp),
                    colors = readerButtonColors(),
                ) {
                    Text("Next", fontSize = 12.sp)
                    Spacer(Modifier.width(5.dp))
                    Icon(Icons.AutoMirrored.Filled.ArrowForward, null, Modifier.size(17.dp))
                }
            }
        }
    }
}

@Composable
private fun readerButtonColors() = ButtonDefaults.filledTonalButtonColors(
    containerColor = Color(0xFF242730),
    contentColor = Color(0xFFF2F3F7),
    disabledContainerColor = Color(0xFF181A20),
    disabledContentColor = Color(0xFF555A66),
)

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ZoomableRemoteSlide(vm: AppViewModel, generationId: String, slide: Int) {
    var scale by remember(slide) { mutableStateOf(1f) }
    var offset by remember(slide) { mutableStateOf(Offset.Zero) }
    val transform = rememberTransformableState { zoom, pan, _ ->
        scale = (scale * zoom).coerceIn(1f, 5f)
        offset = if (scale <= 1f) Offset.Zero else offset + pan
    }
    Box(
        Modifier.fillMaxSize()
            .pointerInput(slide) {
                detectTapGestures(onDoubleTap = { scale = 1f; offset = Offset.Zero })
            }
            // A transformable normally claims one-finger horizontal drags as
            // image pans, which starves the parent pager. At the fitted scale,
            // only multi-touch zoom is handled here; one-finger drags remain
            // available to HorizontalPager. Once zoomed, panning the slide is
            // intentional and double-tap returns it to the pageable state.
            .transformable(state = transform, canPan = { scale > 1f }),
        contentAlignment = Alignment.Center,
    ) {
        RemoteSlideImage(
            vm, generationId, slide, "Slide $slide",
            modifier = Modifier.fillMaxWidth().graphicsLayer {
                scaleX = scale; scaleY = scale
                translationX = offset.x; translationY = offset.y
            },
        )
    }
}

@Composable
private fun WeeklyReportReader(
    generation: WeeklyProgressGenerationSummary,
    vm: AppViewModel,
    theme: ThemePalette,
    onClose: () -> Unit,
) {
    val context = LocalContext.current
    var text by remember(generation.id) { mutableStateOf<String?>(null) }
    var loaded by remember(generation.id) { mutableStateOf(false) }
    LaunchedEffect(generation.id) {
        text = withContext(Dispatchers.IO) {
            WeeklyProgressNet.report(context, vm.weeklyProgressHost(), generation.id)
        }
        loaded = true
    }
    BackHandler(onBack = onClose)
    Dialog(
        onDismissRequest = onClose,
        properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false),
    ) {
        Column(Modifier.fillMaxSize().background(theme.bgDeep)) {
            Row(
                Modifier.fillMaxWidth().background(theme.panel).padding(horizontal = 5.dp, vertical = 5.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                IconButton(onClick = onClose) { Icon(Icons.Filled.Close, "Close", tint = theme.text) }
                Column(Modifier.weight(1f)) {
                    Text(generation.projectName, color = theme.text, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                    Text("Research report · week of ${generation.weekStart}", color = theme.faint, fontSize = 10.sp)
                }
            }
            if (!loaded) Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = theme.accent)
            } else if (text == null) WeeklyEmpty(
                "Report unavailable", "Reconnect to the Mac and try again.", theme
            ) else Box(
                Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 18.dp, vertical = 20.dp)
            ) {
                LabMarkdown(text!!, theme.text, theme.dim, theme.panelAlt, Modifier.fillMaxWidth())
            }
        }
    }
}

@Composable
private fun ProjectChoice(
    name: String,
    detail: String,
    selected: Boolean,
    theme: ThemePalette,
    onClick: () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick)
            .background(if (selected) theme.accent.copy(alpha = .11f) else Color.Transparent)
            .padding(horizontal = 20.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier.size(8.dp).clip(RoundedCornerShape(4.dp))
                .background(if (selected) theme.accent else theme.border)
        )
        Spacer(Modifier.width(12.dp))
        Column {
            Text(name, color = theme.text, fontSize = 14.sp, fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal)
            Text(detail, color = theme.faint, fontSize = 11.sp)
        }
    }
}

@Composable
private fun CalendarWeekHeader(week: String, versions: Int, theme: ThemePalette) {
    Row(verticalAlignment = Alignment.Bottom) {
        Column {
            Text(weekRange(LocalDate.parse(week)), color = theme.text, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
            Text("Week of $week", color = theme.faint, fontSize = 10.sp)
        }
        Spacer(Modifier.weight(1f))
        Text(versionLabel(versions), color = theme.dim, fontSize = 11.sp)
    }
}

@Composable
private fun WeeklyLoading(theme: ThemePalette) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            CircularProgressIndicator(color = theme.accent)
            Spacer(Modifier.height(10.dp))
            Text("Loading reviews from your Mac", color = theme.dim, fontSize = 12.sp)
        }
    }
}

@Composable
private fun WeeklyEmpty(title: String, body: String, theme: ThemePalette) {
    Box(Modifier.fillMaxSize().padding(32.dp), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(Icons.Filled.Slideshow, null, tint = theme.faint, modifier = Modifier.size(38.dp))
            Spacer(Modifier.height(12.dp))
            Text(title, color = theme.text, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(5.dp))
            Text(body, color = theme.dim, fontSize = 12.sp)
        }
    }
}

@Composable
private fun weeklyChipColors(theme: ThemePalette) = FilterChipDefaults.filterChipColors(
    containerColor = Color.Transparent,
    labelColor = theme.dim,
    iconColor = theme.faint,
    selectedContainerColor = theme.selection,
    selectedLabelColor = theme.text,
    selectedLeadingIconColor = theme.accent,
)

private fun currentMonday(): LocalDate =
    LocalDate.now().with(TemporalAdjusters.previousOrSame(DayOfWeek.MONDAY))

private fun weekRange(start: LocalDate): String {
    val format = DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM)
    return "${start.format(format)} – ${start.plusDays(6).format(format)}"
}

private fun projectSourceCount(project: WeeklyProgressProjectSummary): String {
    val parts = mutableListOf<String>()
    if (project.panelCount > 0) parts += "${project.panelCount} ${if (project.panelCount == 1) "panel" else "panels"}"
    if (project.workspaceCount > 0) parts += "${project.workspaceCount} ${if (project.workspaceCount == 1) "folder" else "folders"}"
    return parts.joinToString(" · ").ifBlank { "Configured on the Mac" }
}

private fun stageTitle(stage: String): String = when (stage) {
    "collectingEvidence" -> "Collecting evidence"
    "reconstructingResearch" -> "Reconstructing research"
    "draftingSlides" -> "Building slides"
    "auditingSlides" -> "Checking slides"
    "complete" -> "Ready"
    "failed" -> "Needs attention"
    else -> "Preparing"
}

private fun stateTitle(generation: WeeklyProgressGenerationSummary): String = when (generation.state) {
    "active" -> "IN PROGRESS"
    "complete" -> "READY"
    "failed" -> "FAILED"
    "interrupted" -> "INTERRUPTED"
    else -> generation.state.uppercase()
}

private fun stateColor(state: String, theme: ThemePalette): Color = when (state) {
    "active" -> theme.working
    "complete" -> theme.milestone
    "failed" -> theme.bad
    "interrupted" -> theme.waiting
    else -> theme.faint
}

private fun versionLabel(count: Int) = if (count == 1) "1 version" else "$count versions"

private fun deckFilename(generation: WeeklyProgressGenerationSummary): String {
    val project = generation.projectName.replace(Regex("[^A-Za-z0-9._-]+"), "-").trim('-')
    return "$project-week-of-${generation.weekStart}.pptx"
}
