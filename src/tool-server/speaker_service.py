import re
from dataclasses import dataclass
from pathlib import Path
from tempfile import NamedTemporaryFile
from typing import Iterable

import torch
import torch.nn.functional as F
import torchaudio
import uuid
from speechbrain.inference.speaker import EncoderClassifier
from werkzeug.datastructures import FileStorage

from config import (
    SPEAKER_ANONYMOUS_ASK_CADENCE,
    SPEAKER_KNOWN_THRESHOLD,
    SPEAKER_MAX_SAMPLES,
    SPEAKER_IDENTIFY_MIN_SECONDS,
    SPEAKER_ENROLLMENT_MIN_SECONDS,
    SPEAKER_REINFORCE_MIN_SECONDS,
    SPEAKER_MODEL_DIR,
    SPEAKER_MODEL_NAME,
    SPEAKER_REDUNDANCY_THRESHOLD,
    SPEAKER_REINFORCE_THRESHOLD,
    SPEAKER_REVIEW_THRESHOLD,
)
from repository import Repository


TARGET_SAMPLE_RATE = 16_000


class SpeakerError(ValueError):
    status_code = 400


class SpeakerAudioError(SpeakerError):
    status_code = 422


class SpeakerNotFoundError(SpeakerError):
    status_code = 404


class SpeakerAlreadyEnrolledError(SpeakerError):
    status_code = 409


@dataclass(frozen=True)
class EmbeddedAudio:
    embedding: list[float]
    duration_seconds: float


@dataclass(frozen=True)
class SpeakerMatch:
    status: str
    profile_id: int | None
    display_name: str | None
    similarity: float | None
    duration_seconds: float
    anonymous: bool = False


class SpeakerService:
    def __init__(
        self,
        repository: Repository,
        model_name: str = SPEAKER_MODEL_NAME,
    ):
        self.repository = repository
        self.model_name = model_name

        SPEAKER_MODEL_DIR.mkdir(parents=True, exist_ok=True)

        self.classifier = EncoderClassifier.from_hparams(
            source=model_name,
            savedir=str(SPEAKER_MODEL_DIR),
            run_opts={"device": "cpu"},
        )

    def profiles_response(self) -> dict:
        return {
            "ok": True,
            "profiles": self.list_profiles(),
        }

    def enroll_from_uploads(
        self,
        display_name: str,
        uploads: Iterable[FileStorage],
        anonymous: bool = False,
    ) -> dict:
        audio_paths = self._save_uploads(uploads)

        try:
            if not audio_paths:
                raise SpeakerError(
                    "Provide at least one WAV file in multipart field 'audio'."
                )

            profile = self.enroll(display_name, audio_paths, anonymous=anonymous)

            return {
                "ok": True,
                "profile": profile,
            }
        finally:
            self._delete_temporary_files(audio_paths)

    def normalized_speaker_name(self, name: str) -> str:
        normalized = re.sub(r"\s+", " ", name.strip().lower())

        if not normalized:
            raise SpeakerError("The speaker name must contain letters or numbers.")

        return normalized

    def identify_from_uploads(
        self,
        uploads: Iterable[FileStorage],
    ) -> dict:
        audio_paths = self._save_uploads(uploads)

        try:
            if len(audio_paths) != 1:
                raise SpeakerError(
                    "Provide exactly one WAV file in multipart field 'audio'."
                )

            match = self.identify(audio_paths[0])

            return {
                "ok": True,
                "status": match.status,
                "profile_id": match.profile_id,
                "display_name": match.display_name,
                "similarity": match.similarity,
                "anonymous": bool(match.anonymous),
                "duration_seconds": round(match.duration_seconds, 3),
            }
        finally:
            self._delete_temporary_files(audio_paths)

    def profile_id_for_name(self, name: str) -> str:
        profile_id = re.sub(
            r"[^a-z0-9]+",
            "-",
            name.strip().lower(),
        ).strip("-")

        if not profile_id:
            raise SpeakerError("The speaker name must contain letters or numbers.")

        return profile_id

    def enroll(
        self,
        display_name: str,
        audio_paths: list[Path],
        anonymous: bool = False,
    ) -> dict:
        if not audio_paths:
            raise SpeakerError("Provide at least one audio file.")

        embedded = [self.embed_file(path) for path in audio_paths]

        for sample in embedded:
            if sample.duration_seconds < SPEAKER_ENROLLMENT_MIN_SECONDS:
                raise SpeakerAudioError(
                    "Each enrollment clip must be at least "
                    f"{SPEAKER_ENROLLMENT_MIN_SECONDS:g} seconds "
                    f"(got {sample.duration_seconds:.2f}s)."
                )

        if anonymous:
            display_name = "Anonymous User"
            normalized_name = f"anonymous-user-{uuid.uuid4().hex[:12]}"
        else:
            display_name = display_name.strip()
            if not display_name:
                raise SpeakerError("Provide a non-empty speaker name.")
            normalized_name = self.normalized_speaker_name(display_name)

        profile = self.repository.create_speaker_profile(
            display_name=display_name,
            normalized_name=normalized_name,
            samples=[
                {
                    "embedding": sample.embedding,
                    "duration_seconds": sample.duration_seconds,
                }
                for sample in embedded
            ],
            max_samples=SPEAKER_MAX_SAMPLES,
            anonymous=anonymous,
        )

        if profile is None:
            raise SpeakerAlreadyEnrolledError(
                f"'{display_name}' is already enrolled as a speaker."
            )

        return profile

    def list_profiles(self) -> list[dict]:
        return self.repository.list_speaker_profiles()

    def identify(
        self,
        audio_path: Path,
    ) -> SpeakerMatch:
        sample = self.embed_file(audio_path)
        embedding = torch.tensor(
            sample.embedding,
            dtype=torch.float32,
        )

        profiles = self.repository.speaker_profiles_for_matching()

        best_profile = None
        best_similarity = float("-inf")

        for profile in profiles:
            for stored in profile["samples"]:
                reference = torch.tensor(
                    stored["embedding"],
                    dtype=torch.float32,
                )
                reference = F.normalize(reference, p=2, dim=0)

                similarity = F.cosine_similarity(
                    embedding.unsqueeze(0),
                    reference.unsqueeze(0),
                ).item()

                if similarity > best_similarity:
                    best_similarity = similarity
                    best_profile = profile

        similarity = round(best_similarity, 4) if best_profile is not None else None

        if best_profile is None or best_similarity < SPEAKER_REVIEW_THRESHOLD:
            return SpeakerMatch(
                status="unknown",
                profile_id=None,
                display_name=None,
                similarity=similarity,
                duration_seconds=sample.duration_seconds,
                anonymous=False,
            )

        if best_similarity < SPEAKER_KNOWN_THRESHOLD:
            return SpeakerMatch(
                status="uncertain",
                profile_id=best_profile["id"],
                display_name=best_profile["display_name"],
                similarity=similarity,
                duration_seconds=sample.duration_seconds,
                anonymous=bool(best_profile.get("anonymous", False)),
            )

        return SpeakerMatch(
            status="known",
            profile_id=best_profile["id"],
            display_name=best_profile["display_name"],
            similarity=similarity,
            duration_seconds=sample.duration_seconds,
            anonymous=bool(best_profile.get("anonymous", False)),
        )

    def embed_file(
        self,
        audio_path: Path,
    ) -> EmbeddedAudio:
        waveform, sample_rate = torchaudio.load(audio_path)

        if waveform.numel() == 0:
            raise SpeakerAudioError("Audio file contains no samples.")

        if waveform.shape[0] > 1:
            waveform = waveform.mean(dim=0, keepdim=True)

        if sample_rate != TARGET_SAMPLE_RATE:
            waveform = torchaudio.functional.resample(
                waveform,
                sample_rate,
                TARGET_SAMPLE_RATE,
            )

        duration_seconds = waveform.shape[1] / TARGET_SAMPLE_RATE

        if duration_seconds < SPEAKER_IDENTIFY_MIN_SECONDS:
            raise SpeakerAudioError(
                "Each audio clip must be at least "
                f"{SPEAKER_IDENTIFY_MIN_SECONDS:g} seconds."
            )

        waveform = waveform.to(dtype=torch.float32)

        with torch.inference_mode():
            embedding = self.classifier.encode_batch(waveform)

        embedding = embedding.squeeze().to(dtype=torch.float32)
        embedding = F.normalize(embedding, p=2, dim=0)

        return EmbeddedAudio(
            embedding=embedding.cpu().tolist(),
            duration_seconds=duration_seconds,
        )

    def _save_uploads(
        self,
        uploads: Iterable[FileStorage],
    ) -> list[Path]:
        paths = []

        for uploaded in uploads:
            if uploaded is None or not uploaded.filename:
                continue

            if Path(uploaded.filename).suffix.lower() != ".wav":
                raise SpeakerError("Only WAV audio is supported.")

            with NamedTemporaryFile(
                suffix=".wav",
                delete=False,
            ) as temporary_file:
                uploaded.save(temporary_file)
                paths.append(Path(temporary_file.name))

        return paths

    def _delete_temporary_files(
        self,
        paths: Iterable[Path],
    ) -> None:
        for path in paths:
            path.unlink(missing_ok=True)

    def reinforce_from_uploads(
        self,
        profile_id: int,
        uploads: Iterable[FileStorage],
    ) -> dict:
        audio_paths = self._save_uploads(uploads)

        try:
            if len(audio_paths) != 1:
                raise SpeakerError(
                    "Provide exactly one WAV file in multipart field 'audio'."
                )

            return self.reinforce(profile_id, audio_paths[0])
        finally:
            self._delete_temporary_files(audio_paths)

    def reinforce(
        self,
        profile_id: int,
        audio_path: Path,
    ) -> dict:
        sample = self.embed_file(audio_path)

        if sample.duration_seconds < SPEAKER_REINFORCE_MIN_SECONDS:
            return {
                "ok": True,
                "accepted": False,
                "reason": "clip_too_short",
                "duration_seconds": round(sample.duration_seconds, 3),
                "ask_identification": False,
            }

        new_embedding = F.normalize(
            torch.tensor(sample.embedding, dtype=torch.float32), p=2, dim=0
        )
        stored_samples = self.repository.get_speaker_samples(profile_id)
        if stored_samples is None:
            raise SpeakerNotFoundError(f"Speaker profile '{profile_id}' was not found.")
        stored_embeddings = [
            F.normalize(torch.tensor(s["embedding"], dtype=torch.float32), p=2, dim=0)
            for s in stored_samples
        ]
        best_existing_similarity = None
        if stored_embeddings:
            similarities = [
                F.cosine_similarity(new_embedding.unsqueeze(0), ref.unsqueeze(0)).item()
                for ref in stored_embeddings
            ]
            best_existing_similarity = max(similarities)

            if best_existing_similarity < SPEAKER_REINFORCE_THRESHOLD:
                return {
                    "ok": True,
                    "accepted": False,
                    "reason": "similarity_below_reinforce_threshold",
                    "similarity": round(best_existing_similarity, 4),
                    "ask_identification": False,
                }

            if best_existing_similarity >= SPEAKER_REDUNDANCY_THRESHOLD:
                return {
                    "ok": True,
                    "accepted": False,
                    "reason": "redundant_sample",
                    "similarity": round(best_existing_similarity, 4),
                    "ask_identification": False,
                }

        remove_sample_ids: list[int] = []

        if len(stored_samples) >= SPEAKER_MAX_SAMPLES:
            best_pair_similarity = float("-inf")
            victim_id = None

            for i in range(len(stored_embeddings)):
                for j in range(i + 1, len(stored_embeddings)):
                    similarity = F.cosine_similarity(
                        stored_embeddings[i].unsqueeze(0),
                        stored_embeddings[j].unsqueeze(0),
                    ).item()
                    if similarity > best_pair_similarity:
                        best_pair_similarity = similarity
                        victim_id = stored_samples[i]["id"]

            for idx, ref in enumerate(stored_embeddings):
                similarity = F.cosine_similarity(
                    new_embedding.unsqueeze(0), ref.unsqueeze(0)
                ).item()
                if similarity > best_pair_similarity:
                    best_pair_similarity = similarity
                    victim_id = stored_samples[idx]["id"]

            remove_sample_ids = (
                [victim_id] if victim_id is not None else [stored_samples[0]["id"]]
            )

        profile = self.repository.replace_speaker_samples(
            profile_id=profile_id,
            remove_sample_ids=remove_sample_ids,
            new_embedding=sample.embedding,
            new_duration_seconds=sample.duration_seconds,
        )

        ask_identification = bool(
            profile is not None
            and profile.get("anonymous", False)
            and profile["sample_count"] % SPEAKER_ANONYMOUS_ASK_CADENCE == 0
        )

        return {
            "ok": True,
            "accepted": True,
            "similarity": (
                round(best_existing_similarity, 4)
                if best_existing_similarity is not None
                else None
            ),
            "anonymous": bool(profile.get("anonymous", False)) if profile else None,
            "ask_identification": ask_identification,
            "profile": profile,
        }

    def promote(self, profile_id: int, name: str) -> dict:
        name = name.strip()

        if not name:
            raise SpeakerError("Provide a non-empty speaker name.")

        profile = self.repository.promote_speaker_profile(
            profile_id=profile_id,
            display_name=name,
            normalized_name=self.normalized_speaker_name(name),
        )

        if profile is None:
            raise SpeakerNotFoundError(
                f"Anonymous speaker profile '{profile_id}' was not found or name is taken."
            )

        return profile
