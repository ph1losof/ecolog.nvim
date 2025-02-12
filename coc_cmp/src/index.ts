import {
  ExtensionContext,
  languages,
  CompletionItem,
  CompletionItemKind,
  CompletionItemProvider,
  Position,
  TextDocument,
  workspace,
  MarkupContent,
  CancellationToken,
  CompletionContext,
} from 'coc.nvim';

interface EnvVarInfo {
  value: string;
  type: string;
  source: string;
  comment?: string;
}

interface EcologConfig {
  provider_patterns: {
    cmp: boolean;
  };
}

interface Provider {
  get_completion_trigger?: () => string;
  pattern?: string;
  format_completion?: (item: any, varName: string, varInfo: EnvVarInfo) => any;
}

export class EcologCompletionProvider implements CompletionItemProvider {
  private nvim = workspace.nvim;

  public async provideCompletionItems(
    document: TextDocument,
    position: Position,
    token: CancellationToken,
    context: CompletionContext
  ): Promise<CompletionItem[]> {
    const line = document.getText({
      start: { line: position.line, character: 0 },
      end: { line: position.line, character: position.character },
    });

    try {
      const [hasEcolog, ecolog] = await this.nvim.call('luaeval', [
        'pcall(require, "ecolog")',
      ]);

      if (!hasEcolog) {
        return [];
      }

      const config: EcologConfig = await this.nvim.call('luaeval', [
        'require("ecolog").get_config()',
      ]);

      const envVars: Record<string, EnvVarInfo> = await this.nvim.call('luaeval', [
        'require("ecolog").get_env_vars()',
      ]);

      if (Object.keys(envVars).length === 0) {
        return [];
      }

      const filetype = await this.nvim.eval('&filetype') as string;
      const providers: Provider[] = await this.nvim.call('luaeval', [
        'require("ecolog.providers").get_providers(_A)',
        filetype,
      ]);

      let shouldComplete = false;
      let matchedProvider: Provider | undefined;

      if (config.provider_patterns.cmp) {
        for (const provider of providers) {
          if (provider.get_completion_trigger) {
            const trigger = await this.nvim.call('luaeval', [
              `${provider.get_completion_trigger.toString()}()`,
            ]);
            const parts = trigger.split('.');
            const pattern = parts
              .map((part: string) => part.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'))
              .join('\\.');

            if (
              line.match(new RegExp(pattern + '$')) ||
              (provider.pattern && line.match(provider.pattern))
            ) {
              shouldComplete = true;
              matchedProvider = provider;
              break;
            }
          }
        }
      } else {
        shouldComplete = true;
      }

      if (!shouldComplete) {
        return [];
      }

      const shelter = await this.nvim.call('luaeval', [
        'require("ecolog.shelter")',
      ]);

      const items: CompletionItem[] = [];
      for (const [varName, varInfo] of Object.entries(envVars)) {
        const displayValue = await this.nvim.call('luaeval', [
          `${shelter.is_enabled.toString()}("cmp") and ${shelter.mask_value.toString()}(_A[1], "cmp", _A[2], _A[3]) or _A[1]`,
          [varInfo.value, varName, varInfo.source],
        ]);

        const documentation: MarkupContent = {
          kind: 'markdown',
          value: [
            `**Type:** \`${varInfo.type}\``,
            `**Value:** \`${displayValue}\``,
            varInfo.comment ? `\n**Comment:** ${varInfo.comment}` : '',
          ].join('\n'),
        };

        const item: CompletionItem = {
          label: varName,
          kind: CompletionItemKind.Variable,
          detail: varInfo.source,
          documentation,
        };

        if (matchedProvider && matchedProvider.format_completion) {
          const formattedItem = await this.nvim.call('luaeval', [
            `${matchedProvider.format_completion.toString()}(_A[1], _A[2], _A[3])`,
            [item, varName, varInfo],
          ]);
          Object.assign(item, formattedItem);
        }

        items.push(item);
      }

      return items;
    } catch (error) {
      workspace.nvim.call('coc#util#echo_messages', [['Error', `Error in EcologCompletionProvider: ${error}`]]);
      return [];
    }
  }
}

export async function activate(context: ExtensionContext): Promise<void> {
  const config = workspace.getConfiguration('ecolog');
  const isEnabled = config.get<boolean>('enable', true);

  if (!isEnabled) {
    return;
  }

  const provider = new EcologCompletionProvider();
  context.subscriptions.push(
    languages.registerCompletionItemProvider(
      'ecolog',
      'Environment variables',
      null,
      provider,
      [],
      99
    )
  );
} 